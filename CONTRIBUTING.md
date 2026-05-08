# Contributing

This project is experimental and Ubuntu-focused. Changes should keep the recovery workflow understandable, auditable, and conservative.

Before opening a pull request, run:

```bash
bash tests/run.sh
```

If your change touches USB initialization, udev, systemd, signing, or root-side execution, also update the manual validation checklist in `README.md`.
