# generated helper: emit m0_720p.al / .prj / settings.cfg  (see build_files note)
$ErrorActionPreference = 'Stop'
$root = 'E:\fpga-2026\dsh_code\proj\m0_720p'
$name = 'm0_720p'
$top  = 'm0_720p_top'

$files = @(
 'rtl/lane_lvds_10_1.v',
 'rtl/hdmi_phy_warpper.v',
 'rtl/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v',
 'al_ip/pll_hdmi_720p/pll_hdmi_720p.v',
 'rtl/video_gen720.v',
 'rtl/m0_720p_top.v'
)

function Emit-Xml([string]$prefix) {
    $nl = "`r`n"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8"?>' + $nl)
    [void]$sb.Append('<Project Version="3" Minor="2">' + $nl)
    [void]$sb.Append('    <Project_Created_Time></Project_Created_Time>' + $nl)
    [void]$sb.Append('    <TD_Version>6.2.190657</TD_Version>' + $nl)
    [void]$sb.Append("    <Name>$name</Name>" + $nl)
    [void]$sb.Append('    <HardWare>' + $nl)
    [void]$sb.Append('        <Family>EG4</Family>' + $nl)
    [void]$sb.Append('        <Device>EG4S20BG256</Device>' + $nl)
    [void]$sb.Append('        <Speed></Speed>' + $nl)
    [void]$sb.Append('    </HardWare>' + $nl)
    [void]$sb.Append('    <Source_Files>' + $nl)
    [void]$sb.Append('        <Verilog>' + $nl)
    $o = 1
    foreach ($f in $files) {
        [void]$sb.Append("            <File Path=`"$prefix$f`">" + $nl)
        [void]$sb.Append('                <FileInfo>' + $nl)
        [void]$sb.Append('                    <Attr Name="UsedInSyn" Val="true"/>' + $nl)
        [void]$sb.Append('                    <Attr Name="UsedInP&R" Val="true"/>' + $nl)
        [void]$sb.Append('                    <Attr Name="BelongTo" Val="design_1"/>' + $nl)
        [void]$sb.Append("                    <Attr Name=`"CompileOrder`" Val=`"$o`"/>" + $nl)
        [void]$sb.Append('                </FileInfo>' + $nl)
        [void]$sb.Append('            </File>' + $nl)
        $o++
    }
    [void]$sb.Append('        </Verilog>' + $nl)
    [void]$sb.Append('        <ADC_FILE>' + $nl)
    [void]$sb.Append("            <File Path=`"${prefix}IO.adc`">" + $nl)
    [void]$sb.Append('                <FileInfo>' + $nl)
    [void]$sb.Append('                    <Attr Name="UsedInSyn" Val="true"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="UsedInP&R" Val="true"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="BelongTo" Val="constraint_1"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="CompileOrder" Val="1"/>' + $nl)
    [void]$sb.Append('                </FileInfo>' + $nl)
    [void]$sb.Append('            </File>' + $nl)
    [void]$sb.Append('        </ADC_FILE>' + $nl)
    [void]$sb.Append('        <SDC_FILE>' + $nl)
    [void]$sb.Append("            <File Path=`"${prefix}timing.sdc`">" + $nl)
    [void]$sb.Append('                <FileInfo>' + $nl)
    [void]$sb.Append('                    <Attr Name="UsedInSyn" Val="true"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="UsedInP&R" Val="true"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="BelongTo" Val="constraint_1"/>' + $nl)
    [void]$sb.Append('                    <Attr Name="CompileOrder" Val="2"/>' + $nl)
    [void]$sb.Append('                </FileInfo>' + $nl)
    [void]$sb.Append('            </File>' + $nl)
    [void]$sb.Append('        </SDC_FILE>' + $nl)
    [void]$sb.Append('    </Source_Files>' + $nl)
    [void]$sb.Append('    <FileSets>' + $nl)
    [void]$sb.Append('        <FileSet Name="design_1" Type="DesignFiles">' + $nl)
    [void]$sb.Append('        </FileSet>' + $nl)
    [void]$sb.Append('        <FileSet Name="constraint_1" Type="ConstrainFiles">' + $nl)
    [void]$sb.Append('        </FileSet>' + $nl)
    [void]$sb.Append('    </FileSets>' + $nl)
    [void]$sb.Append('    <TOP_MODULE>' + $nl)
    [void]$sb.Append("        <LABEL>$top</LABEL>" + $nl)
    [void]$sb.Append("        <MODULE>$top</MODULE>" + $nl)
    [void]$sb.Append('        <CREATEINDEX>user</CREATEINDEX>' + $nl)
    [void]$sb.Append('    </TOP_MODULE>' + $nl)
    [void]$sb.Append('    <Property>' + $nl)
    [void]$sb.Append('    </Property>' + $nl)
    [void]$sb.Append('    <Device_Settings>' + $nl)
    [void]$sb.Append('    </Device_Settings>' + $nl)
    [void]$sb.Append('    <Configurations>' + $nl)
    [void]$sb.Append('    </Configurations>' + $nl)
    if ($prefix -eq '') {
        [void]$sb.Append('    <Runs>' + $nl)
        [void]$sb.Append('        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true">' + $nl)
        [void]$sb.Append('            <Strategy Name="Default_Synthesis_Strategy">' + $nl)
        [void]$sb.Append('            </Strategy>' + $nl)
        [void]$sb.Append('            <UserParams>' + $nl)
        [void]$sb.Append('            </UserParams>' + $nl)
        [void]$sb.Append('        </Run>' + $nl)
        [void]$sb.Append('        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true">' + $nl)
        [void]$sb.Append('            <Strategy Name="Default_PhysicalDesign_Strategy">' + $nl)
        [void]$sb.Append('            </Strategy>' + $nl)
        [void]$sb.Append('            <UserParams>' + $nl)
        [void]$sb.Append('            </UserParams>' + $nl)
        [void]$sb.Append('        </Run>' + $nl)
        [void]$sb.Append('    </Runs>' + $nl)
    }
    [void]$sb.Append('    <Project_Settings>' + $nl)
    [void]$sb.Append('    </Project_Settings>' + $nl)
    [void]$sb.Append('</Project>' + $nl)
    return $sb.ToString()
}

$enc = New-Object System.Text.UTF8Encoding($false)

# .al : project file in the project root, plain relative paths
$al = Emit-Xml ''
$al = $al.Replace('<Project Version="3" Minor="2">',
                  ('<Project Version="3" Minor="2" Path="E:/fpga-2026/dsh_code/proj/' + $name + '/' + $name + '">'))
[System.IO.File]::WriteAllText((Join-Path $root "$name.al"), $al, $enc)

# .prj in both run directories, paths relative to <root>/<name>_Runs/<run>
foreach ($r in @('syn_1','phy_1')) {
    $dir = Join-Path $root ("${name}_Runs\" + $r)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir "$name.prj"), (Emit-Xml '../../'), $enc)

    $startStep = if ($r -eq 'syn_1') { 'read_design' } else { 'opt_place' }
    $endStep   = if ($r -eq 'syn_1') { 'opt_gate' }    else { 'bitgen' }
    $runType   = if ($r -eq 'syn_1') { 'syn' }         else { 'phy' }
    $cfg = @()
    $cfg += '# This File is Created by Tang Dynasty.'
    $cfg += 'set ADCList {"../../IO.adc"}'
    $cfg += 'set SDCList {"../../timing.sdc"}'
    $cfg += 'set area_option -packarea'
    if ($r -eq 'phy_1') { $cfg += 'set arr_filter false' }
    $cfg += 'set device_name eagle_s20.db'
    if ($r -eq 'phy_1') { $cfg += 'set drHoldFix on' }
    $cfg += "set end_step $endStep"
    $cfg += 'set package_name EG4S20BG256'
    if ($r -eq 'phy_1') { $cfg += 'set parent ../syn_1' }
    $cfg += "set prj_name {$name}"
    $cfg += "set run_type $runType"
    $cfg += "set start_step $startStep"
    $cfg += "set top_model_name {$top}"
    [System.IO.File]::WriteAllText((Join-Path $dir 'settings.cfg'), (($cfg -join "`r`n") + "`r`n"), $enc)
}
Write-Host "generated .al / .prj / settings.cfg"
Get-ChildItem $root -Recurse -Include *.al,*.prj,settings.cfg | ForEach-Object { $_.FullName }

