"""Persistent home-scoped work identities; owned by fm-tasks-axi.sh work."""
import copy
from fm_progress import tr
import re
import secrets


ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'
ALIAS = re.compile(r'[PST]-[' + ALPHABET + r']{3}')
KEY = re.compile(r'(?:task:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}|project:[A-Za-z0-9_.-]+|subproject:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)')
PATH = 'data/work-aliases.json'


class Aliases:
    def __init__(self, owner, refuse):
        self.owner, self.refuse = owner, refuse
        self.value = owner.read(PATH)
        if self.value is not None:
            self.validate(self.value)

    def validate(self, value):
        self.refuse(not isinstance(value, dict) or value.get('schema') != 'fm-work-aliases.v1'
                    or value.get('home') != str(self.owner.home)
                    or not isinstance(value.get('forward'), dict) or not isinstance(value.get('reverse'), dict),
                    'owner_failed', tr('Identity registry is invalid or belongs to another installation.'))
        for key, alias in value['forward'].items():
            self.refuse(not KEY.fullmatch(key) or not isinstance(alias, str) or not ALIAS.fullmatch(alias)
                        or value['reverse'].get(alias) != key, 'owner_failed', tr('Inconsistent identities.'))
        for alias, key in value['reverse'].items():
            self.refuse(not ALIAS.fullmatch(alias) or not isinstance(key, str) or not KEY.fullmatch(key)
                        or key not in value['forward'], 'owner_failed', tr('Invalid identity reservation.'))

    def sync(self):
        if self.value is None:
            return  # Explicit activation permits private approved allocations before any new ones.
        previous = copy.deepcopy(self.value)
        for key in sorted(self.owner.keys()):
            if key in self.value['forward']:
                continue
            kind = self.owner.hierarchy(key)['kind'] if not key.startswith('task:') else 'task'
            prefix = dict(project='P', subproject='S', task='T')[kind] + '-'
            capacity = len(ALPHABET) ** 3
            start = secrets.randbelow(capacity)
            for offset in range(capacity):
                slot = (start + offset) % capacity
                suffix = ''.join(ALPHABET[(slot // (len(ALPHABET) ** n)) % len(ALPHABET)] for n in (2, 1, 0))
                alias = prefix + suffix
                if alias not in self.value['reverse']:
                    self.value['forward'][key] = alias
                    self.value['reverse'][alias] = key
                    break
            else:
                self.refuse(True, 'owner_failed', tr('Short identities of this type are exhausted.'))
        if previous != self.value:
            self.owner.atomic(PATH, self.value)

    def alias(self, key):
        return (self.value or {}).get('forward', {}).get(key)

    def resolve(self, ref):
        key = (self.value or {}).get('reverse', {}).get(ref, ref)
        self.refuse(not isinstance(key, str) or (key not in self.owner.keys() and key not in (self.value or {}).get('forward', {})),
                    'unknown_target', tr('Unknown identity in this installation.'))
        return key

    def seed(self, source, request_id):
        self.refuse(not isinstance(source, dict) or source.get('schema') != 'fm-work-alias-seed.v1'
                    or source.get('home') != str(self.owner.home) or not isinstance(source.get('entries'), list),
                    'invalid_value', tr('Identity seed is invalid or belongs to another installation.'))
        path = 'data/work-alias-activations/' + request_id + '.json'
        receipt = self.owner.read(path)
        if receipt:
            self.refuse(receipt['seed'] != source, 'request_mismatch', tr('The activation has different content.'))
            self.refuse(receipt['state'] != 'applied', 'owner_failed', tr('Incomplete activation: review its receipt.'))
            return receipt
        before = copy.deepcopy(self.value)
        value = copy.deepcopy(self.value) if self.value is not None else dict(
            schema='fm-work-aliases.v1', home=str(self.owner.home), forward={}, reverse={})
        for entry in source['entries']:
            self.refuse(not isinstance(entry, dict) or set(entry) != {'key', 'alias', 'primary'}
                        or not isinstance(entry['key'], str) or not KEY.fullmatch(entry['key'])
                        or not isinstance(entry['alias'], str) or not ALIAS.fullmatch(entry['alias'])
                        or type(entry['primary']) is not bool,
                        'invalid_value', tr('Invalid identity allocation.'))
            key, alias = entry['key'], entry['alias']
            self.refuse(alias in value['reverse'] and value['reverse'][alias] != key,
                        'request_mismatch', tr('The identity already belongs to another item.'))
            self.refuse(entry['primary'] and key in value['forward'] and value['forward'][key] != alias,
                        'request_mismatch', tr('The item already has a persistent primary identity.'))
            if entry['primary']:
                value['forward'][key] = alias
            value['reverse'][alias] = key
        self.validate(value)
        receipt = dict(schema='fm-work-alias-activation.v1', seed=source, before=before, state='prepared')
        self.owner.atomic(path, receipt)
        self.value = value
        self.owner.atomic(PATH, value)
        self.sync()
        receipt.update(state='applied', after=copy.deepcopy(self.value))
        self.owner.atomic(path, receipt)
        return receipt
