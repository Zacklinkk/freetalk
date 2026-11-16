"""Edited prompts: the user's copy is used when usable, the built-in one otherwise."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))

import prompt_files
from engine import Editor, prompt


def built_messages():
    editor = Editor.__new__(Editor)
    editor.mode, editor.emit = 'edits', (lambda value: None)
    editor.prepare_prefix = lambda base: (None, None)
    editor.set_preferences([])
    return editor


class PromptFileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        prompt_files.overrides = Path(self.directory.name)
        self.addCleanup(setattr, prompt_files, 'overrides', None)

    def write(self, name, text):
        (Path(self.directory.name) / name).write_text(text)

    def test_without_edits_the_built_in_prompts_are_used(self):
        self.assertEqual(prompt_files.source('edit-plan.txt'), prompt_files.builtin('edit-plan.txt'))
        self.assertIn(prompt_files.builtin('edit-rules.txt').removesuffix('\n'), prompt('edit-plan.txt'))
        self.assertNotIn('{{edit-rules}}', prompt('restart-plan.txt'))

    def test_every_editable_prompt_ships_and_examples_are_turns(self):
        for name in prompt_files.EDITABLE:
            with self.subTest(name=name):
                text = prompt_files.builtin(name)
                self.assertTrue(text.strip())
                if name.endswith('.json'):
                    self.assertTrue(prompt_files.valid_turns(text))

    def test_an_edited_rule_reaches_both_prompts_that_share_it(self):
        self.write('edit-rules.txt', '只删口水词。\n')
        editor = built_messages()
        self.assertIn('只删口水词。', editor.base[0]['content'])
        self.assertIn('只删口水词。', editor.restart_base[0]['content'])
        self.assertNotIn(prompt_files.builtin('edit-rules.txt').splitlines()[0], editor.base[0]['content'])

    def test_edited_examples_replace_the_built_in_ones(self):
        turns = [{'role': 'user', 'content': '句子：[[0,"嗯，开始吧。"]]'},
                 {'role': 'assistant', 'content': '{"repairs":[],"edits":[],"breaks":[],"bullets":[]}'}]
        self.write('edit-plan-examples.json', json.dumps(turns, ensure_ascii=False))
        self.assertEqual(built_messages().base[1:], turns)

    def test_unusable_edits_fall_back_to_the_built_in_prompt(self):
        built = built_messages().base
        for name, text in [('edit-plan.txt', '   \n'), ('edit-plan-examples.json', '{broken'),
                           ('edit-plan-examples.json', json.dumps([{'role': 'assistant', 'content': 'x'}, {'role': 'user', 'content': 'y'}])),
                           ('edit-plan-examples.json', json.dumps([{'role': 'user', 'content': 'only one turn'}]))]:
            with self.subTest(name=name, text=text):
                self.write(name, text)
                self.assertEqual(built_messages().base, built)

    def test_an_unknown_marker_is_left_alone_and_other_files_are_ignored(self):
        self.write('edit-plan.txt', '前言 {{no-such-file}} 结尾\n')
        self.assertEqual(prompt('edit-plan.txt'), '前言 {{no-such-file}} 结尾\n')
        self.write('config.json', '{}')
        self.assertIsNone(prompt_files.edited('config.json'))

    def test_preferences_still_follow_an_edited_prompt(self):
        self.write('filler-selection.txt', '只选口水词编号。')
        editor = Editor.__new__(Editor)
        editor.mode, editor.emit = 'edits', (lambda value: None)
        editor.prepare_prefix = lambda base: (None, None)
        editor.set_preferences(['保留句末语气词。'])
        self.assertTrue(editor.filler_base[0]['content'].startswith('只选口水词编号。'))
        self.assertTrue(editor.filler_base[0]['content'].endswith('- 保留句末语气词。\n'))

    def test_settings_list_the_same_files_the_worker_accepts(self):
        # An edit saved for a file the worker does not read would be silently ignored.
        import re
        swift = (Path(__file__).resolve().parents[1] / 'native' / 'PromptFiles.swift').read_text()
        listed = re.findall(r'^\s*\("([a-z-]+\.(?:txt|json))"', swift, re.M)
        self.assertEqual(listed, list(prompt_files.EDITABLE))


if __name__ == '__main__':
    unittest.main()
