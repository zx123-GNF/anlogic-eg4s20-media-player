# bw_probe.tcl -- probe whether BitWriter can see the AL-LINK cable
#   E:\bin\bw_commands_prompt.exe E:/fpga-2026/dsh_code/tools/bw_probe.tcl
proc safe {label script} {
    if {[catch {uplevel 1 $script} res]} {
        puts "FAIL  $label : $res"
    } else {
        puts "OK    $label : $res"
    }
}
puts "== list_cable =="
safe "list_cable" {list_cable}
