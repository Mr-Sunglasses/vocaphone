## Summary

- What changed?
- Why is it needed?

## Verification

- [ ] `uv run ruff check .`
- [ ] `uv run ruff format --check .`
- [ ] `uv run mypy app`
- [ ] `uv run pytest`
- [ ] Compose validation/container build, if deployment files changed
- [ ] iOS simulator build/tests
- [ ] Physical-device test, if keyboard, microphone, background audio, or insertion changed

## Privacy and security

- [ ] No secrets, signing material, recordings, transcripts, or private tailnet details added
- [ ] Documentation updated for data-flow, permission, retention, or network changes
