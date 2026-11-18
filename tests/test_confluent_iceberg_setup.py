"""Exercise setup against fake APIs so tests never modify a real deployment."""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/helpers"))
import confluent_iceberg_setup as integration
from softwarehub_service_instance_helpers import APIError, SoftwareHub, request_json

REAL_PREPARE_IDENTITY = integration.prepare_identity


class RoleTests(unittest.TestCase):
    def hub(self, current=None):
        hub = SoftwareHub("https://hub.example.test", "private-token")
        hub.member = Mock(side_effect=[current, {"role": "Metastore Admin"}])
        hub.user = Mock(return_value={"uid": 42})
        hub.request = Mock()
        return hub

    def test_existing_membership_patch_targets_only_selected_user(self):
        hub = self.hub({"role": "User"})
        self.assertEqual(hub.ensure_role("instance", "svc-test", "Metastore Admin"), "updated")
        hub.request.assert_called_once_with(
            "/zen-data/v2/serviceInstance/users/role", method="PATCH",
            body={"serviceInstanceID": "instance", "roles": [{"uid": "42", "username": "svc-test", "newrole": "Metastore Admin"}]},
        )

    def test_missing_membership_is_added(self):
        hub = self.hub()
        self.assertEqual(hub.ensure_role("instance", "svc-test", "Metastore Admin"), "added")
        hub.request.assert_called_once_with(
            "/zen-data/v2/serviceInstance/users", method="POST",
            body={"serviceInstanceID": "instance", "users": [{"uid": "42", "username": "svc-test", "role": "Metastore Admin"}]},
        )

    def test_matching_role_does_not_write(self):
        hub = self.hub({"role": "Metastore Admin"})
        self.assertEqual(hub.ensure_role("instance", "svc-test", "Metastore Admin"), "unchanged")
        hub.request.assert_not_called()
        hub.user.assert_not_called()

    def test_dry_run_does_not_grant_role(self):
        hub = self.hub({"role": "User"})
        self.assertEqual(hub.ensure_role("instance", "svc-test", "Metastore Admin", dry_run=True), "updated")
        hub.request.assert_not_called()

    def test_reads_members_after_first_page(self):
        hub = SoftwareHub("https://hub.example.test", "private-token")
        hub.request = Mock(side_effect=[
            {"users": [{"user_name": "other"}], "limit": 1, "total_count": 2},
            {"users": [{"user_name": "svc-test", "role": "User"}], "limit": 1, "total_count": 2},
        ])
        self.assertEqual(hub.member("instance", "svc-test")["role"], "User")
        self.assertIn("offset=1", hub.request.call_args.args[0])

    def test_authentication_failure_does_not_print_response_body(self):
        failure = urllib.error.HTTPError(
            "https://hub.example.test/login", 403, "Forbidden", {},
            io.BytesIO(b'{"password":"private-password"}'),
        )
        with patch("urllib.request.urlopen", side_effect=failure), \
                self.assertRaisesRegex(APIError, "HTTP 403") as caught:
            request_json("https://hub.example.test/login", method="POST", body={"password": "private-password"})
        self.assertNotIn("private-password", str(caught.exception))


class ConnectTests(unittest.TestCase):
    def test_credentials_reach_curl_through_stdin(self):
        connect = integration.Connect(SimpleNamespace(namespace="streaming", port="8083"))
        body = {"iceberg.catalog.rest.auth.basic.password": "private-password"}
        with patch.object(integration.subprocess, "run", return_value=Mock(returncode=0, stdout='{}\n200')) as command:
            self.assertEqual(connect.request("PUT", "/connectors/sink/config", body), (200, {}))
        args = command.call_args.args[0]
        self.assertNotIn("private-password", " ".join(args))
        self.assertIn("@-", args)
        self.assertEqual(json.loads(command.call_args.kwargs["input"]), body)


class ConfigGenerationTests(unittest.TestCase):
    def test_fresh_config_keeps_integration_optional_and_accepts_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "pyproject.toml").touch()
            generator = "scripts/install_confluent_platform/0_confluent_prepare_template_config.sh"
            for relative in [generator, *[
                "src/helpers/" + name for name in [
                    "common_helpers.sh", "version_resolver.sh", "legacy_version_resolution.sh",
                    "version_catalog.py", "version_catalog.json", "legacy_version_resolution.py",
                    # a fresh config is written in operator mode, whose KRaft presets live here
                    "confluent_operator_config.py",
                ]
            ]]:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / relative, target)
            result = subprocess.run(["zsh", str(root / generator)], text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            config_dir = root / "configs/confluent_platform_config"
            config = config_dir / "confluent_vars.sh"
            command = 'source "$1"; print -rl -- "$DO_ICEBERG_WATSONX_SETUP" "$ICEBERG_WATSONX_CONFIG_FILE"'
            env = {key: value for key, value in os.environ.items() if key not in [
                "DO_ICEBERG_WATSONX_SETUP", "ICEBERG_WATSONX_CONFIG_FILE",
            ]}
            env["CONFLUENT_CONFIG_DIR"] = str(config_dir)
            defaults = subprocess.run(["zsh", "-c", command, "test", str(config)], env=env, text=True, capture_output=True, check=False)
            self.assertEqual(defaults.returncode, 0, defaults.stderr)
            self.assertEqual(defaults.stdout.splitlines(), ["false", str(config_dir / "iceberg_watsonx_setup.sh")])
            env.update({"DO_ICEBERG_WATSONX_SETUP": "true", "ICEBERG_WATSONX_CONFIG_FILE": str(root / "custom.sh")})
            overrides = subprocess.run(["zsh", "-c", command, "test", str(config)], env=env, text=True, capture_output=True, check=False)
            self.assertEqual(overrides.returncode, 0, overrides.stderr)
            self.assertEqual(overrides.stdout.splitlines(), ["true", str(root / "custom.sh")])


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.platform = self.root / "scripts/install_confluent_platform"
        utilities = self.platform / "utility_scripts_confluent_platform"
        utilities.mkdir(parents=True)
        helpers = self.root / "src/helpers"
        helpers.mkdir(parents=True)
        shutil.copy(REPO / "src/helpers/common_helpers.sh", helpers)
        # The full installer and x.6 read the deploy mode through confluent_helpers.sh; these tests run scripts mode.
        shutil.copy(REPO / "src/helpers/confluent_helpers.sh", helpers)
        # ir_dispatch (common_helpers.sh) reads the run mode through this helper.
        shutil.copy(REPO / "src/helpers/install_runner_mode.sh", helpers)
        # In local mode it then checks the same-type lock (C10), which loads these.
        for name in ("install_runner_lock.sh", "install_runner_slots.sh", "multi_cluster_helpers.sh"):
            shutil.copy(REPO / "src/helpers" / name, helpers)
        shutil.copy(REPO / "scripts/install_confluent_platform/full_installprocess-confluent_platform.sh", self.platform)
        self.trace = self.root / "trace"
        (self.root / "env_bootstrap.sh").write_text(
            f'export _CP4D_REPO_ROOT="{self.root}"\n'
            'export PROJECT_CONFLUENT_SERVER="streaming"\n'
            'DO_ICEBERG_WATSONX_SETUP="${DO_ICEBERG_WATSONX_SETUP:-false}"\n'
        )
        self.config = self.root / "configs/confluent_platform_config/iceberg_watsonx_setup.sh"
        self.config.parent.mkdir(parents=True)
        self.config.write_text('export ICEBERG_CONNECTOR_NAME="selected-connector"\n')
        self.utility = utilities / "x.6_confluent_setup_iceberg_watsonx.sh"
        self.utility.write_text(f'#!/bin/sh\nprintf setup > "{self.trace}"\n')
        self.utility.chmod(0o755)
        self.env = {
            **os.environ,
            "DO_CONFLUENT_PREP": "false", "DO_CONFLUENT_INSTALL": "false",
            "DO_CONFLUENT_STATUS": "false", "DO_CONFLUENT_INSTANCE_DETAILS": "false",
            "DO_FLINK_ADDON": "false", "DO_ICEBERG_WATSONX_SETUP": "false",
            "CONFLUENT_DEPLOY_MODE": "scripts",
        }

    def full_install(self):
        return subprocess.run(["zsh", str(self.platform / "full_installprocess-confluent_platform.sh")], env=self.env, text=True, capture_output=True, check=False)

    def test_full_install_skips_integration_by_default(self):
        result = self.full_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.trace.exists())

    def test_full_install_calls_same_utility_when_enabled(self):
        self.env["DO_ICEBERG_WATSONX_SETUP"] = "true"
        result = self.full_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.trace.read_text(), "setup")

    def test_missing_enabled_config_stops_before_steps(self):
        self.env["DO_ICEBERG_WATSONX_SETUP"] = "true"
        self.config.unlink()
        result = self.full_install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config is missing", result.stderr)
        self.assertFalse(self.trace.exists())

    def test_utility_runs_directly_with_flag_disabled(self):
        shutil.copy(REPO / "scripts/install_confluent_platform/utility_scripts_confluent_platform/x.6_confluent_setup_iceberg_watsonx.sh", self.utility)
        binaries = self.root / "bin"
        binaries.mkdir()
        python = binaries / "python3"
        python.write_text(
            '#!/bin/sh\n'
            f'printf "%s\\n" "$ICEBERG_CONNECTOR_NAME" "$@" > "{self.trace}"\n'
        )
        python.chmod(0o755)
        (binaries / "oc").write_text('#!/bin/sh\nexit 0\n')
        (binaries / "oc").chmod(0o755)
        self.env.update({"PATH": str(binaries) + os.pathsep + self.env["PATH"], "OC_LOGIN": "", "CPD_URL": "https://hub.example.test", "CPD_USERNAME": "admin", "CPD_PASSWORD": "password"})
        result = subprocess.run(["zsh", str(self.utility), "--config", str(self.config), "--service-id", "svc-selected", "--dry-run"], env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text()
        self.assertIn("selected-connector", trace)
        self.assertIn("--service-id\nsvc-selected\n--dry-run", trace)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text("configs/\n")
        target = self.root / "scripts/install_confluent_platform/connector_configs"
        target.mkdir(parents=True)
        shutil.copy(REPO / "scripts/install_confluent_platform/connector_configs/iceberg-avro.example.json", target)
        self.env = {
            "PATH": os.environ["PATH"],
            "PROJECT_CONFLUENT_SERVER": "streaming",
            "CPD_URL": "https://hub.example.test", "CPD_USERNAME": "admin", "CPD_PASSWORD": "admin-password",
            "ICEBERG_KAFKA_TOPIC": "events", "ICEBERG_TABLE": "analytics.events",
            "ICEBERG_WATSONX_CATALOG": "external_catalog",
            "ICEBERG_WATSONX_REST_URI": "https://mds.example.test/api/v1/iceberg",
            "ICEBERG_COS_ENDPOINT": "https://s3.example.test", "ICEBERG_COS_REGION": "region",
            "ICEBERG_COS_ACCESS_KEY_ID": "hmac-access", "ICEBERG_COS_SECRET_ACCESS_KEY": "hmac-secret",
        }
        self.settings = integration.Settings(self.root, self.env)
        self.settings.credentials.parent.mkdir(parents=True)
        self.settings.credentials.write_text("svc-iceberg:sid-password\n")
        self.hub = Mock(token="token")
        self.hub.find_instance.return_value = {"id": "instance"}
        self.hub.user.return_value = {"uid": 42, "authenticator": "external"}
        self.hub.member.return_value = {"role": "Metastore Admin"}
        self.hub.ensure_role.return_value = "unchanged"
        self.connect = Mock()
        self.connect.request.return_value = (404, {})
        self.connect.require.side_effect = self.connect_response
        self.output = io.StringIO()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(contextlib.redirect_stdout(self.output))
        self.stack.enter_context(patch.object(integration.SoftwareHub, "sign_in", return_value=self.hub))
        self.stack.enter_context(patch.object(integration, "Connect", return_value=self.connect))
        self.catalog = self.stack.enter_context(patch.object(integration, "catalog_config", return_value={}))
        self.identity = self.stack.enter_context(patch.object(integration, "prepare_identity", return_value="sid-password"))

    def connect_response(self, method, path, body=None):
        if path == "/connector-plugins":
            return [{"class": integration.CONNECTOR_CLASS, "version": "1.9.2"}]
        if path.endswith("/status"):
            return {"connector": {"state": "RUNNING"}, "tasks": [{"id": 0, "state": "RUNNING"}]}
        return {}

    def deployments(self):
        return [x for x in self.connect.require.call_args_list if x.args[0] == "PUT" and x.args[1].startswith("/connectors/")]

    def test_new_connector_uses_sid_and_writes_private_ignored_config(self):
        integration.setup(self.settings)
        config = json.loads(self.settings.output.read_text())
        self.assertEqual(config["iceberg.catalog.rest.auth.basic.password"], "sid-password")
        self.assertNotIn("admin-password", self.settings.output.read_text())
        self.assertEqual(self.settings.output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.deployments()[0].args[:2], ("PUT", "/connectors/iceberg-sink/config"))
        self.identity.assert_not_called()
        for secret in ["admin-password", "sid-password", "hmac-access", "hmac-secret"]:
            self.assertNotIn(secret, self.output.getvalue())

    def test_second_run_skips_account_plugin_and_connector_update(self):
        self.connect.request.return_value = (200, self.settings.config("sid-password"))
        with patch.object(integration.subprocess, "run") as commands:
            integration.setup(self.settings)
        self.assertFalse(self.deployments())
        self.identity.assert_not_called()
        commands.assert_not_called()

    def test_changed_configuration_updates_same_named_connector(self):
        old = self.settings.config("sid-password")
        old["iceberg.control.commit.interval-ms"] = "60000"
        self.connect.request.return_value = (200, old)
        integration.setup(self.settings)
        self.assertEqual(len(self.deployments()), 1)
        self.assertEqual(self.deployments()[0].args[1], "/connectors/iceberg-sink/config")

    def test_existing_extra_connector_settings_are_preserved(self):
        old = {**self.settings.config("sid-password"), "errors.tolerance": "all"}
        self.connect.request.return_value = (200, old)
        integration.setup(self.settings)
        self.assertFalse(self.deployments())
        self.assertEqual(json.loads(self.settings.output.read_text())["errors.tolerance"], "all")

    def test_name_collision_does_not_replace_another_connector_type(self):
        self.connect.request.return_value = (200, {"connector.class": "another.SourceConnector"})
        with self.assertRaisesRegex(RuntimeError, "another connector type"):
            integration.setup(self.settings)
        self.identity.assert_not_called()
        self.hub.ensure_role.assert_not_called()
        self.assertFalse(self.deployments())

    def test_prepare_only_does_not_deploy(self):
        integration.setup(self.settings, prepare_only=True)
        self.assertTrue(self.settings.output.exists())
        self.assertFalse(self.deployments())

    def test_dry_run_missing_identity_does_not_change_resources_or_files(self):
        self.hub.user.return_value = None
        self.settings.credentials.unlink()
        integration.setup(self.settings, dry_run=True)
        self.identity.assert_not_called()
        self.hub.ensure_role.assert_not_called()
        self.assertFalse(self.settings.output.exists())
        self.assertFalse(self.deployments())

    def test_failed_catalog_preflight_prevents_mutations(self):
        self.catalog.side_effect = APIError("GET", "https://mds.example.test", 404)
        with self.assertRaises(APIError):
            integration.setup(self.settings)
        self.identity.assert_not_called()
        self.hub.ensure_role.assert_not_called()
        self.assertFalse(self.settings.output.exists())

    def test_failed_connector_validation_prevents_role_changes(self):
        self.connect.validate.side_effect = RuntimeError("Invalid topics")
        with self.assertRaisesRegex(RuntimeError, "Invalid topics"):
            integration.setup(self.settings)
        self.identity.assert_not_called()
        self.hub.ensure_role.assert_not_called()
        self.assertFalse(self.deployments())

    def test_missing_sid_and_plugin_reuse_existing_installers(self):
        self.hub.user.return_value = None
        self.hub.member.return_value = None
        self.hub.ensure_role.return_value = "added"
        plugins = iter([[], [{"class": integration.CONNECTOR_CLASS}]])
        original = self.connect_response
        self.connect.require.side_effect = lambda method, path, body=None: next(plugins) if path == "/connector-plugins" else original(method, path, body)
        with patch.object(integration.subprocess, "run", return_value=Mock(returncode=0)) as commands:
            integration.setup(self.settings)
        self.identity.assert_called_once_with(self.settings)
        self.assertIn("x.3_confluent_add_connector.sh", commands.call_args.args[0][1])
        self.hub.ensure_role.assert_called_once_with("instance", "svc-iceberg", "Metastore Admin")

    def test_supplied_bad_password_is_not_rotated(self):
        self.settings.env["ICEBERG_SERVICE_PASSWORD"] = "wrong-password"
        with patch.object(integration, "password_works", return_value=False), \
                self.assertRaisesRegex(RuntimeError, "cannot sign in"):
            integration.setup(self.settings)
        self.identity.assert_not_called()
        self.hub.ensure_role.assert_not_called()

    def test_unreachable_sid_login_does_not_trigger_repair(self):
        with patch.object(integration, "password_works", side_effect=APIError("POST", "https://hub.example.test", 503)), \
                self.assertRaises(APIError):
            integration.setup(self.settings)
        self.identity.assert_not_called()

    def test_missing_inputs_fail_before_contacting_services(self):
        env = {**self.env, "ICEBERG_COS_SECRET_ACCESS_KEY": "<SECRET>"}
        with self.assertRaisesRegex(ValueError, "ICEBERG_COS_SECRET_ACCESS_KEY"):
            integration.Settings(self.root, env)

    def test_mode_on_with_no_cluster_refuses_the_flat_output(self):
        state = self.root / "configs/multi_cluster_management.sh"
        state.parent.mkdir(exist_ok=True)
        state.write_text('export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS="a b"\nexport MCM_CURRENT_CLUSTER=""\n')
        with self.assertRaisesRegex(ValueError, "no cluster is selected"):
            integration.Settings(self.root, self.env)

    def test_tracked_output_is_rejected(self):
        env = {**self.env, "ICEBERG_OUTPUT_FILE": str(self.root / "tracked.json")}
        with self.assertRaisesRegex(ValueError, "ignored by Git"):
            integration.Settings(self.root, env)

    def test_identity_helper_cannot_change_parent_kubeconfig(self):
        original_env = {**self.env, "KUBECONFIG": "/original/context", "ENV_TARGET": "confluent"}
        self.settings.env = original_env
        seen = {}

        def run(args, **kwargs):
            if args[:3] == ["oc", "config", "view"]:
                return Mock(stdout="private-kubeconfig", returncode=0)
            child = kwargs["env"]
            seen["path"] = Path(child["KUBECONFIG"])
            self.assertEqual(seen["path"].stat().st_mode & 0o777, 0o600)
            self.assertEqual(child["ENV_TARGET"], "cpd")
            self.assertNotEqual(child["KUBECONFIG"], original_env["KUBECONFIG"])
            return Mock(returncode=0, stdout="new-password", stderr="")

        # Exercise the real account orchestration with only its subprocesses mocked.
        self.stack.enter_context(patch.object(integration, "prepare_identity", REAL_PREPARE_IDENTITY))
        with patch.object(integration.subprocess, "run", side_effect=run), patch.object(integration.shutil, "which", return_value="/bin/tool"):
            self.assertEqual(integration.prepare_identity(self.settings), "sid-password")
        self.assertEqual(self.settings.env["KUBECONFIG"], "/original/context")
        self.assertFalse(seen["path"].exists())
        self.assertNotIn("private-kubeconfig", self.output.getvalue())


class OperatorModeTests(unittest.TestCase):
    """Operator mode (contract 5.5): pod/connect-0 as the REST target, and CONFLUENT_CONNECTOR_MANAGEMENT=cr."""

    SECRETS: ClassVar[dict[str, str]] = {
        "iceberg.catalog.rest.auth.basic.password": "pw:with=special#chars",
        "iceberg.catalog.s3.access-key-id": "private-access-key",
        "iceberg.catalog.s3.secret-access-key": "private-secret-key",
    }

    def settings(self, root, **env):
        return SimpleNamespace(namespace="streaming", port="8083", name="iceberg-sink", root=root,
                               env={"PROJECT_CONFLUENT_SERVER": "streaming", "CFO_OWNER_ID": "local.streaming", **env})

    def argv(self, connect):
        with patch.object(integration.subprocess, "run", return_value=Mock(returncode=0, stdout="[]\n200")) as command:
            connect.request("GET", "/connector-plugins")
        return command.call_args.args[0]

    def test_default_connect_target_keeps_todays_argv(self):
        args = self.argv(integration.Connect(SimpleNamespace(namespace="streaming", port="8083")))
        self.assertEqual(args[:8], ["oc", "exec", "-i", "deployment/connect", "-n", "streaming", "--", "curl"])

    def test_operator_target_and_container(self):
        connect = integration.Connect(SimpleNamespace(namespace="streaming", port="8083"),
                                      target="pod/connect-0", container="connect")
        args = self.argv(connect)
        self.assertEqual(args[:10], ["oc", "exec", "-i", "pod/connect-0", "-n", "streaming", "-c", "connect", "--", "curl"])

    def test_main_passes_target_container_and_management(self):
        seen = {}

        def fake_setup(settings, **kwargs):
            seen.update(kwargs)

        argv = ["x", "--repo-root", str(REPO), "--connect-target", "pod/connect-0", "--connect-container", "connect",
                "--management", "cr", "--dry-run"]
        with patch.object(sys, "argv", argv), patch.object(integration, "Settings", return_value=SimpleNamespace(namespace="streaming", port="8083")), \
                patch.object(integration, "setup", side_effect=fake_setup):
            self.assertEqual(integration.main(), 0)
        self.assertEqual(seen["management"], "cr")
        self.assertEqual((seen["connect"].target, seen["connect"].container), ("pod/connect-0", "connect"))
        self.assertTrue(seen["dry_run"])

    def test_state_file_gets_the_secret_once_with_mode_600(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "cfg/confluent_connect_state.json"
            self.assertTrue(integration.connect_state_add_secret(state, "iceberg-watsonx-credentials"))
            self.assertFalse(integration.connect_state_add_secret(state, "iceberg-watsonx-credentials"))
            data = json.loads(state.read_text())
            self.assertEqual(data["mounted_secrets"], ["iceberg-watsonx-credentials"])
            self.assertEqual(data["schema_version"], 1)
            self.assertEqual(state.stat().st_mode & 0o777, 0o600)

    def test_secret_values_reach_oc_through_stdin_only(self):
        cr = integration.ConnectorCR(self.settings(REPO))
        with patch.object(integration.subprocess, "run", return_value=Mock(returncode=0, stdout="", stderr="")) as command:
            cr.apply_secret({"topics": "t", **self.SECRETS})
        args, kwargs = command.call_args.args[0], command.call_args.kwargs
        self.assertEqual(args, ["oc", "apply", "-f", "-"])
        manifest = json.loads(kwargs["input"])
        text = manifest["stringData"][integration.CR_SECRET_KEY]
        self.assertIn("iceberg.catalog.rest.auth.basic.password=pw\\:with\\=special\\#chars", text)
        self.assertNotIn("topics", text)
        self.assertEqual(manifest["metadata"]["labels"]["confluent.ibm-scripts/installed-by"], "local.streaming")

    @unittest.skipUnless((REPO / ".venv/bin/python").exists(), "needs the repo venv (jinja2, PyYAML)")
    def test_connector_cr_references_the_mounted_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            integration.connect_state_add_secret(state, integration.CR_SECRET)
            cr = integration.ConnectorCR(self.settings(REPO, CONFLUENT_CONNECT_STATE_FILE=str(state)))
            config = {"name": "iceberg-sink", "connector.class": integration.CONNECTOR_CLASS, "tasks.max": "2",
                      "topics": "orders", **self.SECRETS}
            text = cr.render(config)
        self.assertIn("kind: Connector", text)
        self.assertIn("taskMax: 2", text)
        self.assertIn("topics: orders", text)
        for prop in self.SECRETS:
            self.assertIn(f"{prop}: ${{file:/mnt/secrets/{integration.CR_SECRET}/{integration.CR_SECRET_KEY}:{prop}}}", text)
        for value in self.SECRETS.values():
            self.assertNotIn(value, text)


if __name__ == "__main__":
    unittest.main()
