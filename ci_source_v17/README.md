# Albay V17 Phase 2 ARM64 pair CI source

The numbered Base64 parts reconstruct a SHA-256-pinned minimal Albay 1.0.45 source archive. GitHub Actions builds the exact V16 MoveList baseline and V17 candidate with Android NDK 29.0.14206865, API 29, static libc++, portable ARMv8-A flags, ThinLTO off and PGO off. The artifact is for physical-device A/B testing; no Android speed claim is made by the CI build alone.
