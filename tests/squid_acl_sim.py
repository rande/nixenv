#!/usr/bin/env python3
"""A small model of squid's http_access evaluation, for testing GENERATED configs.

Why this exists: what matters is not just what squid allows or denies,
but whether it RESOLVES a hostname along the way. A `dst` ACL needs the
destination address, so evaluating one against a hostname makes squid do a DNS
lookup — and a lookup for a denied name is a data channel to whoever runs that
name's DNS server. This model reports both the verdict and whether any lookup
would have happened.

Modelled, as squid documents them:
  * http_access rules are checked top-down; the first matching rule wins.
  * within a rule, ACLs are ANDed left to right and evaluation stops at the
    first one that fails (so a later `dst` ACL is never evaluated).
  * `!acl` negates.
  * acl types: src, dst, dstdomain [-n], port, method.
  * dstdomain: `.foo.com` matches foo.com and any subdomain; a plain entry is
    exact. Without -n, an IP-literal URL triggers a REVERSE lookup.
  * dst: an IP-literal URL needs no lookup; a hostname does.

Usage:
  squid_acl_sim.py <squid.conf> <src-ip> <METHOD> <host> <port> [name=ip ...]
Prints:  <allow|deny> dns=<yes|no>
The optional name=ip pairs are what a lookup would return (default: a public
TEST-NET-3 address), so a rebinding case can be modelled.
"""
import ipaddress
import sys


def parse(path):
    # `all` is squid's one predefined ACL: every configuration may use it
    # without declaring it.
    acls, rules = {"all": ("src", [], ["0.0.0.0/0", "::/0"])}, []
    with open(path) as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if parts[0] == "acl":
                name, typ, args = parts[1], parts[2], parts[3:]
                flags = [a for a in args if a.startswith("-")]
                vals = [a for a in args if not a.startswith("-")]
                if name in acls:
                    acls[name][2].extend(vals)
                else:
                    acls[name] = (typ, flags, vals)
            elif parts[0] == "http_access":
                rules.append((parts[1], parts[2:]))
    return acls, rules


def is_ip(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def in_any(addr, cidrs):
    a = ipaddress.ip_address(addr)
    return any(a in ipaddress.ip_network(c, strict=False) for c in cidrs)


def match(acl, req, state, resolve):
    typ, flags, vals = acl
    if typ == "src":
        return in_any(req["src"], vals)
    if typ == "dstdomain":
        host = req["host"].lower()
        if is_ip(host) and "-n" not in flags:
            state["dns"] = True  # reverse lookup of the IP-literal URL
        for v in (x.lower() for x in vals):
            if v.startswith("."):
                if host == v[1:] or host.endswith(v):
                    return True
            elif host == v:
                return True
        return False
    if typ == "dst":
        host = req["host"]
        if is_ip(host):
            addr = host
        else:
            state["dns"] = True
            addr = resolve.get(host, "203.0.113.10")
        return in_any(addr, vals)
    if typ == "port":
        return str(req["port"]) in vals
    if typ == "method":
        return req["method"] in vals
    raise SystemExit(f"unsupported acl type in model: {typ}")


def evaluate(acls, rules, req, resolve):
    state = {"dns": False}
    for action, names in rules:
        matched = True
        for n in names:
            neg = n.startswith("!")
            name = n.lstrip("!")
            if name not in acls:
                raise SystemExit(f"undefined acl: {name}")
            m = match(acls[name], req, state, resolve)
            if neg:
                m = not m
            if not m:
                matched = False
                break  # short-circuit: later ACLs in this rule are not evaluated
        if matched:
            return action, state["dns"]
    return "deny", state["dns"]


def main(argv):
    if len(argv) < 6:
        raise SystemExit(__doc__)
    conf, src, method, host, port = argv[1:6]
    resolve = dict(kv.split("=", 1) for kv in argv[6:])
    acls, rules = parse(conf)
    verdict, dns = evaluate(acls, rules,
                            {"src": src, "method": method, "host": host, "port": port},
                            resolve)
    print(f"{verdict} dns={'yes' if dns else 'no'}")


if __name__ == "__main__":
    main(sys.argv)
