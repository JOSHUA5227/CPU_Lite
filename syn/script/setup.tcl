set search_path [list . ../src ./script /fetools/work_area/frontend/SAED32_EDK/lib/stdcell_lvt/db_nldm]
set target_library [list saed32lvt_ss0p75v25c.db]
set link_library "* $target_library "
set designer "joshua"
set symbol_library lsi_10k.sdb
set synthetic_library dw_foundation.sldb
alias rc "report_constraint -all_violators"
