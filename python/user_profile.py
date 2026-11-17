"""The user profile that nightly maintenance builds from dictation history.

The app counts the words in recent dictations (native/UserProfile.swift) and
sends only those words and counts, never sentences. A strong cloud model
infers the user's domains and lists the terms those domains use (benchmark,
SFT, LoRA). The terms become low-priority hotwords for transcription
(vocabulary.asr_hotwords); cleanup never sees them and they change no text by
themselves. The prompt is prompts/user-profile.txt.
"""
import json
import re

from cloud_client import CloudUnavailable, json_object

MAX_STATISTICS = 150
MAX_DOMAINS = 5
MAX_TERMS = 40
TERM = re.compile(r"[A-Za-z0-9一-鿿][A-Za-z0-9一-鿿 +.#@&/'-]{0,39}")


def clean_terms(values, limit=MAX_TERMS):
    """Terms as hotwords: short, one line, no sentence; anything else is dropped."""
    terms, seen = [], set()
    for value in values if isinstance(values, list) else []:
        # A term spans one line; one that breaks across lines is not a term.
        if not isinstance(value, str) or re.search(r'[\r\n\t]', value):
            continue
        term = re.sub(r' +', ' ', value).strip()
        chinese = len(re.findall(r'[一-鿿]', term))
        if (not TERM.fullmatch(term) or term.isdigit() or len(term) < 2 or chinese > 8
                or len(term.split(' ')) > 3 or (chinese and ' ' in term)):
            continue
        if term.casefold() not in seen:
            seen.add(term.casefold())
            terms.append(term)
    return terms[:limit]


def clean_domains(values):
    domains = []
    for value in values if isinstance(values, list) else []:
        if isinstance(value, str):
            domain = re.sub(r'\s+', ' ', value).strip()
            if 2 <= len(domain) <= 12 and not any(ord(c) < 32 for c in domain) and domain not in domains:
                domains.append(domain)
    return domains[:MAX_DOMAINS]


def request(statistics, dictations):
    """The user message: word counts only. Rows that are not a short word are dropped."""
    rows = []
    for row in statistics if isinstance(statistics, list) else []:
        if isinstance(row, dict) and isinstance(row.get('count'), int) and clean_terms([row.get('term')]):
            rows.append({'词': row['term'].strip(), '次数': row['count']})
    return json.dumps({'口述条数': int(dictations), '高频词': rows[:MAX_STATISTICS]}, ensure_ascii=False)


def build(complete, statistics, dictations, timeout=120):
    """Ask the strong model; return {'domains', 'terms'} or raise CloudUnavailable."""
    from prompt_files import source
    reply = complete([{'role': 'system', 'content': source('user-profile.txt')},
                      {'role': 'user', 'content': request(statistics, dictations)}], 2000, timeout)
    try:
        value = json_object(reply)
    except ValueError:
        raise CloudUnavailable('invalid_json') from None
    return {'domains': clean_domains(value.get('domains')), 'terms': clean_terms(value.get('terms'))}
