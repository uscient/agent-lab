#!/usr/bin/env python3
"""Regression for three inputs an independent audit found the contract split on.

Each manifest below was accepted by the pinned CUE and refused by the Python
derivation, so the product failed closed with InfrastructureError instead of
refusing cleanly. Two were authority fields CUE supplied when the author omitted
them; one was a declared-secret subset rule that lived in a hidden field the
plan projection never referenced.

Run from the repository root. Exit 0 when every input is cleanly refused.
"""
import importlib.util,sys,json
sp=importlib.util.spec_from_file_location('ex','scripts/experiment.py')
m=importlib.util.module_from_spec(sp); sys.modules['ex']=m; sp.loader.exec_module(m)
IMG={"digestRef":"registry.example/team/hub@sha256:"+"a"*64}
def man(s): return {"apiVersion":"agent-lab/v0alpha2","kind":"Experiment","metadata":{"name":"plan-authority"},"spec":s}
cases=[("missing-assurance",man({"secrets":[{"name":"broker-token","reference":"agent-lab.secret/broker-token"}],
  "authority":{"install":{"principal":"declared-lab-operator","secrets":["broker-token"]}},
  "members":[{"name":"hub","image":IMG,"secretGrants":["broker-token"]}]})),
 ("missing-authority-secrets",man({"secrets":[{"name":"broker-token","reference":"agent-lab.secret/broker-token"}],
  "authority":{"install":{"principal":"declared-lab-operator","assurance":"declared"}},
  "members":[{"name":"hub","image":IMG,"secretGrants":["broker-token"]}]})),
 ("undeclared-grant",man({"secrets":[],"members":[{"name":"hub","image":IMG,"secretGrants":["broker-token"]}]}))]
bad=0
for n,mf in cases:
    try: m.cue_plan_v0alpha2(mf); r="ACCEPTED"; bad+=1
    except m.InvalidManifest: r="refused"
    except m.InfrastructureError: r="DISAGREEMENT"; bad+=1
    print(f"{n}: {r}")
print("FAIL" if bad else "PASS", "audit-regression", bad, "of", len(cases), "not cleanly refused")
sys.exit(1 if bad else 0)
