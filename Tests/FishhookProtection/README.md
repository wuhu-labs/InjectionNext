# Fishhook section protection regression

On a Mac with Xcode, from this repository root:

```bash
xcrun clang -DFISHHOOK_EXPORT -Wno-nullability-completeness -I Sources/InjectionNextC/include Tests/FishhookProtection/regression.c -o /tmp/fishhook-protection-test
/tmp/fishhook-protection-test
```

The fixture allocates a read-only page with a pointer section that starts one pointer past the page boundary. Rebinding must change the pointer, capture its old value, and restore read-only protection. The former unchecked `mprotect` used the unaligned section address and crashed on the protected write. The patched implementation checks `vm_protect` with `VM_PROT_COPY` and looks up the binding section's actual protection, not the rebinding list's protection.

The narrow C override originates from `SwiftTrace/SwiftTraceGuts/fishhook.c` at submodule revision `3dd80b3aee1cbdd1ed503ef57145021a5d594d30` (the InjectionNext fork base is `62a1f3b359336dcd1100e251df5fc1b4aa1cdefe`). Its license is preserved. `Package.swift` excludes that original source; all other SwiftTrace sources remain unchanged. Delete the override and exclusion when the upstream submodule fixes the same protection behavior.

The fixture also injects failed region lookup, failed write permission, and failed permission restoration. Lookup/write failures skip rebinding without guessing protection; restoration failure returns -1 and records an unrecoverable load error. `fishhook_reset_protection_error` and `fishhook_protection_error` form a thread-local error channel for callers whose upstream reloader ignores fishhook return values. Reset immediately before a synchronous patch, then check immediately afterward and reject the load before sweeping or announcing success. A failed restore may already have applied some symbols; it is not a transactional rollback. Restart the development app after any protection failure.
