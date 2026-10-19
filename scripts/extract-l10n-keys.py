#!/usr/bin/env python3
"""Lists the localizable keys used by the SwiftUI sources (Text/Button/Label/... literals and String(localized:))."""
import re, sys, glob

CALLS = r'(?:Text|Button|Label|Section|Toggle|TextField|Picker|LabeledContent|Stepper|CommandMenu|Link|ContentUnavailableView|TableColumn|WindowGroup)'
LIT = r'"((?:[^"\\]|\\.)*)"'
patterns = [
    re.compile(CALLS + r'\(\s*' + LIT),
    re.compile(r'String\(localized:\s*' + LIT),
    re.compile(r'\.help\(\s*' + LIT),
    re.compile(r'prompt:\s*' + LIT),
    re.compile(r'(?:title|message|action):\s*' + LIT),
    re.compile(r'case \.\w+:\s*' + LIT),               # LocalizedStringKey enum titles
    re.compile(r'LocalizedStringKey\(\s*' + LIT),
    re.compile(r'\?\s*' + LIT + r'\s*:\s*' + LIT),      # ternaries: both branches (second group handled below)
    re.compile(r'(?:section|pane)\(\s*' + LIT),
]
INT_EXPRS = {"port", "times", "count", "status", "model.port", "model.paused.count", "model.visibleFlows.count", "model.flows.count"}
SKIP = {"", " ", "+", "−", "—", "#"}

def swift_to_key(lit):
    # interpolations -> format specifiers
    out, i = "", 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth and j < len(lit):
                depth += {"(": 1, ")": -1}.get(lit[j], 0); j += 1
            expr = lit[i + 2:j - 1]
            out += "%lld" if expr.strip() in INT_EXPRS else "%@"
            i = j
        else:
            out += lit[i]; i += 1
    return out

def keys():
    found = {}
    for path in sorted(glob.glob("Sources/ProxioApp/*.swift")):
        text = open(path).read()
        for pat in patterns:
            for m in pat.finditer(text):
                for lit in m.groups():
                    key = swift_to_key(lit)
                    if key in SKIP or not re.search(r'[A-Za-z]{2}', key) or key.startswith("http") or "/" in key and " " not in key:
                        continue
                    found.setdefault(key, path)
    return found

if __name__ == "__main__":
    for k, p in keys().items():
        print(f"{p.split('/')[-1]}\t{k}")
