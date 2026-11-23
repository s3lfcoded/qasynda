"""Комментарий к переводу — канал связи с незнакомым человеком.

Ссылки, домены, телеграм-ники и номера телефонов в нём — основа схемы «я ошибочно перевёл, верните вот сюда»,
поэтому они запрещены. Проверка идёт по тексту, приведённому к простому виду: NFKC (широкие и стилизованные
буквы и цифры → обычные), невидимые символы удалены, похожие кириллические буквы заменены латинскими,
любые «точки» — обычной точкой. Сохраняется исходный текст, только без невидимых символов.
"""
from __future__ import annotations

import re
import unicodedata

# Символы, которые не видны на экране, но не относятся к категориям C/Z (Unicode Default_Ignorable_Code_Point).
_IGNORABLE = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160), (0x17B4, 0x17B5),
    (0x180B, 0x180F), (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164),
    (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A),
    (0xE0000, 0xE0FFF),
)

# Кириллические и греческие буквы, неотличимые от латинских.
_CONFUSABLE = str.maketrans({
    "а": "a", "в": "b", "е": "e", "ё": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c",
    "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ɡ": "g", "ԛ": "q", "ԝ": "w",
    "α": "a", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "ν": "v", "κ": "k", "ι": "i", "ε": "e",
})
_DOTS = str.maketrans({c: "." for c in "。｡．·•∙․‧⋅⸱"})

_TLDS_LATIN = (
    "com|net|org|ru|kz|su|by|ua|uz|kg|tj|tm|am|az|ge|me|io|co|app|dev|site|online|store|shop|top|xyz|info|biz|"
    "pro|club|link|click|live|life|tech|space|website|fun|icu|vip|cc|tv|ws|gg|ly|to|pw|bet|win|cash|money|pay|"
    "tg|im|ai|eu|us|uk|de|cn|tk|ml|ga|cf|gq|page|blog|news|world|today|best|art|bio|one|plus"
)
_TLDS_CYRILLIC = "рф|қаз|каз|бел|укр|срб|мкд|рус|онлайн|сайт|орг|ком|дети|москва"

_LINK = re.compile(r"https?:|www\.|\b(?:t|wa|vk|ok)\s?\.\s?me\b")
_DOMAIN_LATIN = re.compile(r"[a-z0-9][a-z0-9-]{0,62}\s?\.\s?(?:" + _TLDS_LATIN + r")\b")
_DOMAIN_CYRILLIC = re.compile(r"[^\W_][\w-]{0,62}\s?\.\s?(?:" + _TLDS_CYRILLIC + r")\b")
_HANDLE = re.compile(r"@[a-z0-9_]{4,}")
# Десять и больше цифр подряд с короткими разделителями между ними: пробелы, дефисы, скобки, точки, «/».
_PHONE = re.compile(r"\d(?:[^\w]{0,3}\d){9,}")


class NoteNotAllowed(ValueError):
    pass


def _invisible(ch: str) -> bool:
    if unicodedata.category(ch) in ("Cc", "Cf", "Co", "Cs", "Cn") and ch not in "\t\n\r":
        return True
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in _IGNORABLE)


def clean(note: str | None) -> str | None:
    """Удаляет невидимые и управляющие символы (в том числе разворот текста), разделители превращает
    в пробелы и схлопывает их. Пустой комментарий → None. Ссылки и номера → NoteNotAllowed."""
    if note is None:
        return None
    kept = []
    for ch in note:
        if _invisible(ch):
            continue
        kept.append(" " if unicodedata.category(ch)[0] == "Z" or ch in "\t\n\r" else ch)
    text = " ".join("".join(kept).split())
    if not text:
        return None
    plain = unicodedata.normalize("NFKC", text).lower().translate(_DOTS)
    plain = "".join(ch for ch in plain if not _invisible(ch))
    latin = plain.translate(_CONFUSABLE)
    if (_LINK.search(latin) or _DOMAIN_LATIN.search(latin) or _DOMAIN_CYRILLIC.search(plain)
            or _HANDLE.search(latin) or _PHONE.search(plain)):
        raise NoteNotAllowed(text)
    return text
