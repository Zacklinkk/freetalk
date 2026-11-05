import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('publish_release', Path(__file__).resolve().parents[1]/'scripts/publish-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_unpublished_draft_is_found_before_git_tag_exists(self):
        draft = {'id':42, 'tag_name':'v0.3.0', 'draft':True}
        with patch.object(release, 'api', return_value=[draft]) as request:
            self.assertEqual(release.release_for_tag('v0.3.0'), draft)
            self.assertIn('/releases?per_page=', request.call_args.args[0])

    def test_release_search_includes_older_pages(self):
        first_page = [{'tag_name':f'v9.0.{i}'} for i in range(100)]
        with patch.object(release, 'api', side_effect=[first_page, [{'id':42,'tag_name':'v0.3.0'}]]):
            self.assertEqual(release.release_for_tag('v0.3.0')['id'], 42)

    def test_unknown_version_is_not_a_release_and_previews_are_not_stable(self):
        with patch.object(release, 'api', return_value=[]):
            self.assertIsNone(release.release_for_tag('v0.3.0'))
        with self.assertRaises(ValueError):
            release.version_tuple('0.3.0-beta.1')
        self.assertGreater(release.version_tuple('0.3.10'), release.version_tuple('0.3.9'))


if __name__ == '__main__':
    unittest.main()
