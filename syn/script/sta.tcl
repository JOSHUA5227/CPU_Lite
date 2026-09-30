read_ddc ./mapped/mapped_cpu_interface.ddc
read_sdc ./script/cpu_constraints.sdc
check_timing

report_clock > clock_reports.rpt

report_clock -skew > clock_skew_reports.rpt

report_timing -delay_type max -nworst 20 -max_paths 20 -path_type full_clock_expanded > setup.rpt

report_timing -delay_type min -nworst 20 -max_paths 20 -path_type full_clock_expanded > hold.rpt

report_timing -delay_type max -nworst 20 -max_paths 20 -from [all_registers] -to [all_registers] > setup_fast_clk.rpt

report_timing -delay_type max -nworst 20 -max_paths 20 > setup_slow_clk.rpt

# Fast clock hold
report_timing -delay_type min -nworst 20 -max_paths 20 > hold_fast_clk.rpt

# Slow clock hold
report_timing -delay_type min -nworst 20 -max_paths 20 > hold_slow_clk.rpt

report_constraint -all_violators > all_violations.rpt

report_analysis_coverage > analysis_coverage.rpt
