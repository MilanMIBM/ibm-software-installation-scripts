"""Permission changes preserve existing members and preflight requested identities."""

import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src/helpers'))
import dph_membership as dph


class MembershipTests(unittest.TestCase):
    def setUp(self):
        self.api = Mock()
        self.members = []
        self.writes = []
        self.api.request.side_effect = self.request
        self.api.user.side_effect = lambda name: {'uid': 'user-' + name} if name != 'missing' else None
        self.api.collection.return_value = [{'name': 'DPH Consumers', 'group_id': 12}]
        self.output = contextlib.redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def request(self, path, *, method='GET', body=None):
        if path == '/v2/catalogs/ibm-default-hub':
            return {'metadata': {'guid': 'hub'}}
        if method != 'GET':
            self.writes.append((path, method, body))
            self.members.extend(body['members'])
            return {'members': body['members'], 'failures': []}
        if path.startswith('/v2/catalogs/hub/members?'):
            return {'members': list(self.members), 'total_results': len(self.members)}
        member_id = path.split('/')[-1].split('?')[0]
        key = 'access_group_id' if 'member_type=group' in path else 'user_iam_id'
        return {'members': [m for m in self.members if str(m.get(key, '')) == member_id]}

    def test_resolves_all_users_before_any_additions(self):
        with self.assertRaisesRegex(RuntimeError, 'missing: user is not registered'):
            dph.ensure_members(self.api, ['valid', 'missing'], [], 'viewer')
        self.assertEqual(self.writes, [])

    def test_dry_run_reads_users_without_changing_membership(self):
        dph.ensure_members(self.api, ['alice', 'bob'], [], 'editor', dry_run=True)
        self.assertEqual(self.writes, [])
        self.assertEqual(self.members, [])

    def test_existing_admin_is_preserved_when_viewer_requested(self):
        self.members = [{'user_iam_id': 'user-alice', 'role': 'admin'}]
        dph.ensure_members(self.api, ['alice'], [], 'viewer')
        self.assertEqual(self.writes, [])
        self.assertEqual(self.members[0]['role'], 'admin')

    def test_group_is_added_once_without_expanding_its_users(self):
        dph.ensure_members(self.api, [], ['DPH Consumers', '12'], 'viewer')
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0][2], {'members': [{'access_group_id': '12', 'role': 'viewer'}]})
        self.api.user.assert_not_called()
        self.assertTrue(any('member_type=group' in call.args[0] for call in self.api.request.call_args_list))

    def test_unverified_write_fails(self):
        original = self.api.request.side_effect

        def request(path, **kwargs):
            if '/members/user-alice?' in path:
                return {'members': []}
            return original(path, **kwargs)

        self.api.request.side_effect = request
        with self.assertRaisesRegex(RuntimeError, 'could not be verified'):
            dph.ensure_members(self.api, ['alice'], [], 'viewer')

    def test_repeated_user_flags_are_all_processed(self):
        with patch.dict('os.environ', {'CPD_URL': 'https://hub.example', 'CPD_USERNAME': 'operator'}), \
                patch.object(dph.SoftwareHub, 'sign_in', return_value=self.api):
            dph.main(['--user', 'alice', '--user', 'bob', '--role', 'viewer'])
        self.assertEqual(len(self.writes), 2)

    def test_catalog_members_follow_bookmarks(self):
        api = Mock()
        api.request.side_effect = [
            {'members': [{'user_iam_id': '1'}], 'nextBookmark': 'next+page'},
            {'members': [{'user_iam_id': '2'}]},
        ]
        self.assertEqual(len(dph.catalog_members(api, '/members')), 2)
        self.assertIn('bookmark=next%2Bpage', api.request.call_args.args[0])

    def test_repeated_bookmark_fails(self):
        api = Mock()
        api.request.return_value = {'members': [{'user_iam_id': '1'}], 'nextBookmark': 'same'}
        with self.assertRaisesRegex(RuntimeError, 'did not advance'):
            dph.catalog_members(api, '/members')


if __name__ == '__main__':
    unittest.main()
