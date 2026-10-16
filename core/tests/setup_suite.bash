# core/tests/setup_suite.bash — bats loads this once for any run of files in this directory (bats-core finds
# setup_suite.bash beside the first test file named, or in the directory named).
setup_suite() {
  # Many suites run the whole upgrade or setup in a fixture home under the real HOME. Without this, the upgrade's
  # step 7 and setup's command phase would write ~/.local/bin/daedalus on the machine running the tests, pointing
  # at a temporary home. The tests of the shim unset it and point HOME and SHELL at scratch.
  export DAEDALUS_NO_COMMAND=1
}
