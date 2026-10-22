# bw_program.tcl -- program an Anlogic FPGA with BitWriter's Tcl shell
#
#   E:\bin\bw_commands_prompt.exe E:/fpga-2026/dsh_code/tools/bw_program.tcl
#
# Parameters come from environment variables (the Tcl shell treats extra
# command-line words as more script files, so argv is not usable):
#
#   BW_MODE   jtag (default, program SRAM) | program_spi | verify_spi
#             | erase_spi | x_rdbk | refresh
#   BW_BIT    path to the .bit file          (required)
#   BW_SPD    TCK speed in MHz, default 5    (lower it if the download is flaky)
#   BW_CABLE  cable index, default 0
#
# Prints the device id first, then the download log, then a clear verdict.

proc env_or {name def} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $def
}

set mode  [env_or BW_MODE  jtag]
set bit   [env_or BW_BIT   ""]
set spd   [env_or BW_SPD   5]
set cable [env_or BW_CABLE 0]

if {$bit eq ""} { puts "ERROR: BW_BIT not set"; exit 2 }
if {![file exists $bit]} { puts "ERROR: bit file not found: $bit"; exit 2 }
puts "bit   : $bit ([file size $bit] bytes)"
puts "mode  : $mode"
puts "spd   : $spd MHz"
puts "cable : $cable"

puts "--- list_cable ---"
if {[catch {list_cable} e]} { puts "FAIL list_cable: $e"; exit 3 }

puts "--- read_device_id ---"
if {[catch {read_device_id} id]} { puts "FAIL read_device_id: $e" ; }
if {[info exists id]} { puts "device: $id" }

puts "--- download ---"
set rc [catch {
    download -bit $bit -mode $mode -spd $spd -cable $cable
} res]
puts "download catch-rc=$rc res=$res"
puts "=== BW_DONE ==="
