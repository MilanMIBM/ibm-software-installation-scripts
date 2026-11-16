"""Community membership operations used by 5_add_dph_member.sh.

Platform roles and hub catalog membership are separate requirements. This helper
only adds catalog collaborators; it preserves existing roles and group members.
"""

import argparse
import os
from urllib.parse import quote, urlencode

from softwarehub_service_instance_helpers import SoftwareHub


def catalog_members(api, path):
    """Read bookmark pages; reject a repeated bookmark to avoid an endless scan."""
    members, seen = [], set()
    bookmark = None
    while True:
        query = {'member_type': 'all', 'limit': 200}
        if bookmark:
            query['bookmark'] = bookmark
        page = api.request(path + '?' + urlencode(query))
        batch = page.get('members', [])
        members.extend(batch)
        total = page.get('total_results')
        if not batch or (total is not None and len(members) >= int(total)):
            return members
        bookmark = page.get('nextBookmark')
        if not bookmark:
            return members
        if bookmark in seen:
            raise RuntimeError('Catalog membership pagination did not advance')
        seen.add(bookmark)


def ensure_members(api, users, groups, role, *, dry_run=False):
    """Resolve every requested identity before adding any catalog collaborators."""
    catalog = api.request('/v2/catalogs/ibm-default-hub')['metadata']['guid']
    targets = []
    for username in users:
        user = api.user(username)
        if not user:
            raise RuntimeError(f'{username}: user is not registered in Software Hub')
        targets.append((username, str(user['uid']), 'user', 'user_iam_id'))
    known_groups = api.collection('/usermgmt/v4/groups', 'results') if groups else []
    for name in groups:
        matches = [g for g in known_groups if name in (str(g['group_id']), g['name'])]
        if len(matches) != 1:
            raise RuntimeError(f'{name}: expected exactly one matching Software Hub group')
        group = matches[0]
        targets.append((group['name'], str(group['group_id']), 'group', 'access_group_id'))
    path = f'/v2/catalogs/{quote(catalog, safe="")}/members'
    members = catalog_members(api, path)
    for label, member_id, member_type, member_key in targets:
        current = next((m for m in members if str(m.get(member_key, '')) == member_id), None)
        if current:
            print(f'{label}: existing community role is {current["role"]}; unchanged')
            continue
        print(('Would add' if dry_run else 'Adding'), label, 'as', role, 'to catalog', catalog)
        member = {member_key: member_id, 'role': role}
        if not dry_run:
            result = api.request(path + '?auth_scope=ibm_data_product_catalog&auth_cache=true',
                                 method='POST', body={'members': [member]})
            if result.get('failures'):
                raise RuntimeError(f'Membership API reported failures: {result["failures"]}')
            verified = api.request(path + '/' + quote(member_id, safe='') + '?member_type=' + member_type)
            if not any(str(m.get(member_key, '')) == member_id and m.get('role') == role
                       for m in verified.get('members', [])):
                raise RuntimeError(f'{label}: addition returned, but membership could not be verified')
            print(f'Verified: {label} is a community {role}')
        members.append(member)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog='5_add_dph_member.sh',
        description='Add a user or Software Hub group to the existing Data Product Hub community.',
        epilog='Run through 5_add_dph_member.sh to load the selected cluster environment. '
        'Users and groups must already exist and need matching DPH platform roles. '
        'Existing community roles, platform roles and group members are preserved. '
        'Uses the same unverified TLS mode as the repository CPD API shell helper.',
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--user', action='append', default=[],
                        help='Existing Software Hub username/email; repeat for several users')
    target.add_argument('--group', action='append', default=[],
                        help='Existing Software Hub group name or numeric ID; repeat for several groups')
    parser.add_argument('--role', choices=['admin', 'editor', 'viewer'], required=True,
                        help='Community role: admin=administrator, editor=producer, viewer=consumer')
    parser.add_argument('--dry-run', action='store_true', help='Read configuration and report the proposed addition')
    args = parser.parse_args(argv)
    for key in ('CPD_URL', 'CPD_USERNAME'):
        if not os.environ.get(key):
            parser.error(f'{key} is missing; run through 5_add_dph_member.sh and check the selected cluster configuration')
    print(f'Authenticating to {os.environ["CPD_URL"]} as {os.environ["CPD_USERNAME"]}')
    api = SoftwareHub.sign_in(
        os.environ['CPD_URL'], os.environ['CPD_USERNAME'],
        password=os.environ.get('CPD_PASSWORD', ''), api_key=os.environ.get('CPD_APIKEY', ''), verify=False,
    )
    ensure_members(api, args.user, args.group, args.role, dry_run=args.dry_run)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, KeyError) as exc:
        raise SystemExit(str(exc)) from None
