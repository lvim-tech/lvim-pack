.PHONY: test fmt

# The suite runs in a bare headless nvim: no config, no framework. The sibling
# lvim-* checkouts beside this one are picked up when they exist (or from
# $LVIM_PLUGINS_DIR); specs that need one they cannot find skip.
test:
	nvim --headless -u NONE -l tests/run.lua

fmt:
	stylua lua tests
