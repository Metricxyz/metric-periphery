# Default commands
test *args: (test-forge args)
build *args: (build-forge args)
prep *args: fix (test-forge args)

# Forge commands
test-forge *args: build-forge
    forge test --isolate {{args}}

build-forge *args: install-forge
    forge build {{args}}

install-forge:
    git submodule update --init --recursive
    forge install

# Formatting
fix:
    forge fmt

# Enable local git hooks (.githooks/pre-commit + pre-push)
hooks:
    node scripts/enable-git-hooks.cjs
