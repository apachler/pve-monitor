# Getting support

`pve-monitor` is a small, single-file Perl Nagios/Icinga2 plugin maintained by
volunteers. Please pick the channel that fits what you need:

| What you need                                | Where to go                                                                  |
| -------------------------------------------- | ---------------------------------------------------------------------------- |
| Read the docs                                | [`README.md`](README.md), or `perldoc pve-monitor.pl`                        |
| Report a defect                              | [Open a bug issue](../../issues/new?template=bug_report.yml)                 |
| Suggest a feature                            | [Open a feature issue](../../issues/new?template=feature_request.yml)        |
| Report a security vulnerability *(private)*  | See [`SECURITY.md`](SECURITY.md)                                             |
| Contribute a change                          | See [`CONTRIBUTING.md`](CONTRIBUTING.md)                                     |
| Behavior / conduct concerns                  | See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)                               |

## Before opening an issue

A few minutes spent here saves a round trip in the issue thread:

1. Confirm you're on a current release — `perl pve-monitor.pl --version` vs
   the [latest release](../../releases/latest).
2. Re-run with `--debug --json` and capture stdout + stderr. The bug template
   asks for both.
3. If it's a parser problem, try `--dry-run` against your config — that
   isolates "the parser refused this block" from "the API call failed."
4. If it's an auth or TLS problem, the most common causes are a stale token
   (`monitor_token_id` + `monitor_token_secret`) and a self-signed cert combined
   with `--verify-ssl`. The README's *Authentication* section walks through both.

## What we don't do

* Live chat / Slack / Discord — there isn't one, and we'd rather respond on
  the issue tracker where the answer is searchable.
* Backporting fixes to old releases unless there is an explicit security
  reason — please reproduce on the latest tag first.
* Generic Proxmox VE / Icinga2 / Nagios support — those projects have their
  own communities better placed to help.
