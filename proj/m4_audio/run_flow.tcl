# CI wrapper for Anlogic TD DefaultFlow.
# Run from a directory that contains settings.cfg (syn_1 or phy_1).
#   E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m4_audio/run_flow.tcl
# Success -> "TD_FLOW_OK" + exit 0 ; failure -> "TD_FLOW_FAILED: ..." + exit 1
set rc [catch { source E:/scripts/DefaultFlow.tcl } err]
if {$rc} {
    puts "TD_FLOW_FAILED: $err"
    exit 1
}
puts "TD_FLOW_OK"
exit 0
