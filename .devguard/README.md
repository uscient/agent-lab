# .devguard

Plaintext guard configuration for `scripts/dev/guard-diff`.

Files:

- `forbid-default.txt`: always checked.
- `forbid-<scope>.txt`: checked when running `scripts/dev/guard-diff <scope>`.

Example:

```bash
./scripts/dev/guard-diff release
```

Then `.devguard/forbid-release.txt` is applied in addition to defaults.
