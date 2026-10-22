"""Reject missing or overlapping QA accounts without printing secret values."""
import os
import sys


def validate(env):
    slot = env.get('IRGUN_QA_SLOT', '')
    if slot not in ('2', '3'):
        raise ValueError('Extended tests require dedicated QA slot 2 or 3.')
    emails = [env.get('IRGUN_QA_EMAIL_' + str(i), '').strip().casefold()
              for i in (1, 2, 3)]
    if not all(emails):
        raise ValueError('Add all three dedicated QA email secrets before running isolated tests.')
    if len(set(emails)) != 3:
        raise ValueError('The three QA email secrets must identify different accounts; refusing concurrent mutations.')
    selected = env.get('IRGUN_TEST_EMAIL', '').strip().casefold()
    if selected != emails[int(slot) - 1]:
        raise ValueError('Selected QA credentials do not match the account concurrency slot.')
    if not env.get('IRGUN_TEST_PASSWORD', '').strip():
        raise ValueError('The selected QA password secret is missing.')
    return slot


if __name__ == '__main__':
    try:
        slot = validate(os.environ)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    print('Dedicated QA slot ' + slot + ' configured; no credentials recorded.')
