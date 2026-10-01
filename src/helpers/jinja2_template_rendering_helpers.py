import os
import sys
import jinja2
from jinja2 import meta, Environment, BaseLoader, FileSystemLoader, Undefined


class _TrackingUndefined(Undefined):
    """Jinja2 Undefined subclass that records every missing variable name."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # _undefined_name is set by Jinja2 internals
        if self._undefined_name is not None:
            _TrackingUndefined._missing.add(self._undefined_name)

    # Allow attribute access and item access on missing vars without raising
    def __getattr__(self, name):
        _TrackingUndefined._missing.add(name)
        return self

    def __getitem__(self, key):
        _TrackingUndefined._missing.add(key)
        return self

    def __str__(self):
        return ""

    def __repr__(self):
        return ""

    def __iter__(self):
        return iter([])

    def __bool__(self):
        return False

    _missing: set = set()


def _collect_caller_locals() -> dict:
    """Walk up the call stack and merge locals from all frames above this module."""
    this_file = os.path.abspath(__file__)
    collected: dict = {}
    frame = sys._getframe(2)  # start above render_template_from_environment
    while frame is not None:
        if os.path.abspath(frame.f_code.co_filename) != this_file:
            collected.update(frame.f_locals)
        frame = frame.f_back
    return collected


def render_template_from_environment(
    template_path: str | None = None,
    template_text: str | None = None,
    extra_vars: dict | None = None,
    print_missing: bool = True,
) -> str | None:
    """Render a Jinja2 template against all variables currently in scope.

    Variable priority (highest wins):
        1. extra_vars (explicit overrides)
        2. Caller's locals/globals from every frame in the call stack
            (captures marimo widget objects and any other in-memory state)
        3. os.environ

    Accepts either a path to a template file or raw template text.
    When print_missing=True, any unresolved template variables are printed.

    Returns the rendered string.
    """
    if template_path is None and template_text is None:
        raise ValueError("Provide either template_path or template_text.")
    if template_path is not None and template_text is not None:
        raise ValueError("Provide template_path OR template_text, not both.")

    if template_path is not None:
        template_path = os.path.expanduser(template_path)
        if not os.path.isfile(template_path):
            raise FileNotFoundError(f"Template file not found: {template_path}")
        template_dir = os.path.dirname(os.path.abspath(template_path))
        template_name = os.path.basename(template_path)
        loader = FileSystemLoader(template_dir)
    else:
        loader = BaseLoader()
        template_name = None

    # Build context: env < caller locals < explicit overrides
    context: dict = dict(os.environ)
    context.update(_collect_caller_locals())
    if extra_vars:
        context.update(extra_vars)

    # Use static analysis to find declared variables before rendering
    analysis_env = Environment(loader=loader)
    if template_path is not None:
        source = analysis_env.loader.get_source(analysis_env, template_name)[0]
    else:
        source = template_text

    declared_vars: set[str] = set()
    try:
        ast = analysis_env.parse(source)
        declared_vars = meta.find_undeclared_variables(ast)
    except jinja2.TemplateSyntaxError:
        pass  # Surface the error during actual render below

    # Reset the tracking set and render
    _TrackingUndefined._missing = set()

    env = Environment(
        loader=loader,
        undefined=_TrackingUndefined,
        keep_trailing_newline=True,
    )

    if template_path is not None:
        tmpl = env.get_template(template_name)
    else:
        tmpl = env.from_string(template_text)

    rendered = tmpl.render(context)

    missing = _TrackingUndefined._missing | (declared_vars - context.keys())
    if print_missing and missing:
        print("Missing template variables (not found in environment):")
        for var in sorted(missing):
            print(f"  - {var}")

    return rendered
