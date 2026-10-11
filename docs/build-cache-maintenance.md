# Build cache maintenance

On this Mac, `scripts/build-macos.sh` and `scripts/check-portable.sh` automatically
supervise their entire Rust/Swift sequence. Tests and packaging reuse compiler
output within the job. When the command finishes, a quiet background janitor
retires its Rust and Swift compiler intermediates. The command returns its own
result immediately, including failures; agents need no extra cleanup step.

Final Rust libraries/executables, Swift products/resources, packaged apps,
source, dependency downloads and every build/acceptance receipt remain.
Active or locked caches are queued for hourly retry. `.keep-target` inside a
build root opts out. Unmodified temporary audit checkouts also qualify for
hourly cleanup after ten quiet minutes. Other platforms/machines without the
installed macOS janitor retain the existing command behavior.
