Native process orchestration with typed, explicit Jev decisions.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/monotykamary/jev-fabric/main/install.sh | sh
npx skills add monotykamary/jev-fabric
```

| Archive | Platform |
| --- | --- |
| `jev-fabric-darwin-universal.tar.gz` | macOS 11+, Apple silicon and Intel |
| `jev-fabric-linux-x64.tar.gz` | Linux x86_64, glibc 2.35+ |
| `jev-fabric-linux-arm64.tar.gz` | Linux aarch64, glibc 2.35+ |

Update later with `jev-fabric -- update`, which reruns the installer.

Each archive holds the `jev-fabric` executable, the Bend library (`native/`) for
`jev-fabric -- run` programs, single-file Python and TypeScript clients
(`clients/`) for `jev-fabric -- serve` sessions, the examples and the agent skill. Verify with
`SHA256SUMS`; the installer does this for you. Jev calls need the system libcurl or
`curl` and a CA store; compiling your own Bend programs needs Bend 2.0.34.
