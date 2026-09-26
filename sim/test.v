`timescale 1ns/1ps

module cpu_core_tb;

    // ============================================================
    // PARAMETERS - MATCH DUT
    // ============================================================

    parameter PROG_ADDR_WIDTH = 12;
    parameter DATA_ADDR_WIDTH = 14;
    parameter DATA_WIDTH      = 32;

    // ============================================================
    // CLOCK / RESET
    // ============================================================

    reg clk;
    reg rst_n;

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ============================================================
    // CPU PORTS
    // ============================================================

    wire [DATA_WIDTH-1:0] instruction;
    wire [PROG_ADDR_WIDTH-1:0] pc;

    wire [DATA_WIDTH-1:0] rdata;
    wire cpu_ready;

    wire cpu_req;
    wire read_write;
    wire [DATA_ADDR_WIDTH-1:0] addr;
    wire [DATA_WIDTH-1:0] wdata;

    // ============================================================
    // DUT
    // ============================================================

    cpu_core #(
        .PROG_ADDR_WIDTH(PROG_ADDR_WIDTH),
        .DATA_ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),

        .instruction (instruction),
        .pc          (pc),

        .rdata       (rdata),
        .cpu_ready   (cpu_ready),

        .cpu_req     (cpu_req),
        .read_write  (read_write),
        .addr        (addr),
        .wdata       (wdata)
    );

    // ============================================================
    // PROGRAM MEMORY
    // ============================================================

    reg [DATA_WIDTH-1:0] program_memory [0:4095];

    assign instruction = program_memory[pc];

    // ============================================================
    // DATA MEMORY
    // ============================================================

    reg [DATA_WIDTH-1:0] data_memory [0:16383];

    /*
     * Registered response.
     *
     * This intentionally behaves more like a real memory/cache
     * interface than:
     *
     *     assign rdata = data_memory[addr];
     *
     * The CPU must receive a stable rdata when cpu_ready is asserted.
     */

    reg [DATA_WIDTH-1:0] rdata_reg;
    reg                  cpu_ready_reg;

    assign rdata     = rdata_reg;
    assign cpu_ready = cpu_ready_reg;

    always @(posedge clk) begin

        cpu_ready_reg <= 1'b0;

        if (cpu_req) begin

            if (read_write) begin

                // STORE
                data_memory[addr] <= wdata;
                cpu_ready_reg     <= 1'b1;

            end
            else begin

                // LOAD
                rdata_reg         <= data_memory[addr];
                cpu_ready_reg     <= 1'b1;

            end

        end

    end

    // ============================================================
    // OPCODES - MATCH DUT EXACTLY
    // ============================================================

    localparam [7:0] NOP       = 8'h00;
    localparam [7:0] LOAD      = 8'h01;
    localparam [7:0] LOAD_IND  = 8'h02;
    localparam [7:0] LOAD_IMM  = 8'h03;
    localparam [7:0] STORE     = 8'h04;
    localparam [7:0] STORE_IND = 8'h05;

    localparam [7:0] ADD       = 8'h06;
    localparam [7:0] SUB       = 8'h07;
    localparam [7:0] MUL       = 8'h08;
    localparam [7:0] AND_OP    = 8'h09;
    localparam [7:0] OR_OP     = 8'h0A;
    localparam [7:0] NOT_OP    = 8'h0B;
    localparam [7:0] CMP       = 8'h0C;
    localparam [7:0] EQ        = 8'h0D;

    localparam [7:0] JMP       = 8'h0E;
    localparam [7:0] JMP_IF    = 8'h0F;

    localparam [7:0] XOR_OP    = 8'h10;
    localparam [7:0] SHL       = 8'h11;
    localparam [7:0] SHR       = 8'h12;
    localparam [7:0] SAR       = 8'h13;
    localparam [7:0] ROL       = 8'h14;
    localparam [7:0] ROR       = 8'h15;

    localparam [7:0] ADDI      = 8'h16;
    localparam [7:0] SUBI      = 8'h17;
    localparam [7:0] ANDI      = 8'h18;
    localparam [7:0] ORI       = 8'h19;
    localparam [7:0] XORI      = 8'h1A;
    localparam [7:0] MOV       = 8'h1B;
    localparam [7:0] SLT       = 8'h1C;
    localparam [7:0] SLTU      = 8'h1D;
    localparam [7:0] LUI       = 8'h1E;

    localparam [7:0] BEQ       = 8'h20;
    localparam [7:0] BNE       = 8'h21;
    localparam [7:0] BLT       = 8'h22;
    localparam [7:0] BGE       = 8'h23;
    localparam [7:0] BLTU      = 8'h24;
    localparam [7:0] BGEU      = 8'h25;
    localparam [7:0] JMP_REG   = 8'h26;

    localparam [7:0] CALL      = 8'h27;
    localparam [7:0] RET       = 8'h28;

    localparam [7:0] HALT      = 8'hFF;

    // ============================================================
    // FSM STATE VALUES - MATCH DUT
    // ============================================================

    localparam [2:0] RESET_STATE       = 3'd0;
    localparam [2:0] FETCH_STATE       = 3'd1;
    localparam [2:0] DECODE_STATE      = 3'd2;
    localparam [2:0] EXECUTE_STATE     = 3'd3;
    localparam [2:0] EXECUTE_WAIT_STATE= 3'd4;
    localparam [2:0] MEMORY_STATE      = 3'd5;
    localparam [2:0] WRITEBACK_STATE   = 3'd6;
    localparam [2:0] HLT_STATE         = 3'd7;

    // ============================================================
    // TEST COUNTERS
    // ============================================================

    integer passed;
    integer failed;

    // ============================================================
    // INSTRUCTION ENCODERS
    // ============================================================

    /*
     * Register format:
     *
     * [31:24] opcode
     * [23:20] rd
     * [19:16] rs1
     * [15:12] rs2
     * [11:0]  zero
     */

    function [31:0] ENC_R;
        input [7:0] opcode_in;
        input [3:0] rd_in;
        input [3:0] rs1_in;
        input [3:0] rs2_in;

        begin
            ENC_R = {
                opcode_in,
                rd_in,
                rs1_in,
                rs2_in,
                12'b0
            };
        end
    endfunction

    /*
     * Immediate format:
     *
     * [31:24] opcode
     * [23:20] rd
     * [19:16] rs1
     * [15:12] unused
     * [11:0]  immediate
     */

    function [31:0] ENC_I;
        input [7:0] opcode_in;
        input [3:0] rd_in;
        input [3:0] rs1_in;
        input [11:0] imm_in;

        begin
            ENC_I = {
                opcode_in,
                rd_in,
                rs1_in,
                4'b0,
                imm_in
            };
        end
    endfunction

    /*
     * Jump/branch format:
     *
     * [31:24] opcode
     * [23:20] zero
     * [19:16] zero
     * [15:12] zero
     * [11:0]  target
     */

    function [31:0] ENC_J;
        input [7:0] opcode_in;
        input [11:0] target_in;

        begin
            ENC_J = {
                opcode_in,
                4'b0,
                4'b0,
                4'b0,
                target_in
            };
        end
    endfunction

    // ============================================================
    // UTILITY TASKS
    // ============================================================

    task clear_program;

        integer i;

        begin
            for (i = 0; i < 4096; i = i + 1)
                program_memory[i] = {NOP,24'b0};
        end

    endtask


    task clear_data_memory;

        integer i;

        begin
            for (i = 0; i < 16384; i = i + 1)
                data_memory[i] = 32'b0;
        end

    endtask


    task reset_cpu;

        begin

            rst_n = 1'b0;

            repeat (3)
                @(posedge clk);

            rst_n = 1'b1;

            repeat (2)
                @(posedge clk);

        end

    endtask


    /*
     * Wait for HLT.
     *
     * Your DUT explicitly defines:
     *
     * HLT = 3'd7
     */

    task wait_for_halt;

        integer timeout;

        begin

            timeout = 0;

            while ((dut.present_state !== HLT_STATE) &&
                   (timeout < 500)) begin

                @(posedge clk);

                timeout = timeout + 1;

            end

            if (timeout >= 500) begin

                $display("ERROR: CPU TIMEOUT waiting for HLT");
                failed = failed + 1;

            end
            else begin

                $display("CPU reached HLT state.");

            end

        end

    endtask


    // ============================================================
    // CHECK REGISTER
    // ============================================================

    task check_reg;

        input integer reg_num;
        input [31:0] expected;

        begin

            if (dut.R[reg_num] === expected) begin

                $display(
                    "PASS: R%0d = 0x%08h",
                    reg_num,
                    dut.R[reg_num]
                );

                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: R%0d expected 0x%08h, got 0x%08h",
                    reg_num,
                    expected,
                    dut.R[reg_num]
                );

                failed = failed + 1;

            end

        end

    endtask


    // ============================================================
    // CHECK MEMORY
    // ============================================================

    task check_memory;

        input integer address;
        input [31:0] expected;

        begin

            if (data_memory[address] === expected) begin

                $display(
                    "PASS: MEM[0x%04h] = 0x%08h",
                    address,
                    data_memory[address]
                );

                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: MEM[0x%04h] expected 0x%08h, got 0x%08h",
                    address,
                    expected,
                    data_memory[address]
                );

                failed = failed + 1;

            end

        end

    endtask


    // ============================================================
    // CHECK PSR
    // ============================================================

    task check_psr;

        input [3:0] expected;

        begin

            if (dut.psr === expected) begin

                $display(
                    "PASS: PSR = %04b",
                    dut.psr
                );

                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: PSR expected %04b, got %04b",
                    expected,
                    dut.psr
                );

                failed = failed + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 1
    // LOAD_IMM + MOV
    // ============================================================

    task test_load_imm_mov;

        begin

            $display("");
            $display("============================================");
            $display("TEST 1: LOAD_IMM / MOV");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h123);

            program_memory[1] =
                ENC_I(MOV,2,1,12'h000);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'h00000123);
            check_reg(2,32'h00000123);

        end

    endtask


    // ============================================================
    // TEST 2
    // ARITHMETIC
    // ============================================================

    task test_arithmetic;

        begin

            $display("");
            $display("============================================");
            $display("TEST 2: ARITHMETIC");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'd10);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'd3);

            program_memory[2] =
                ENC_R(ADD,3,1,2);

            program_memory[3] =
                ENC_R(SUB,4,1,2);

            program_memory[4] =
                ENC_R(MUL,5,1,2);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'd13);
            check_reg(4,32'd7);
            check_reg(5,32'd30);

        end

    endtask


    // ============================================================
    // TEST 3
    // LOGICAL OPERATIONS
    // ============================================================

    task test_logical;

        begin

            $display("");
            $display("============================================");
            $display("TEST 3: LOGICAL OPERATIONS");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hAAA);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h555);

            program_memory[2] =
                ENC_R(AND_OP,3,1,2);

            program_memory[3] =
                ENC_R(OR_OP,4,1,2);

            program_memory[4] =
                ENC_R(XOR_OP,5,1,2);

            program_memory[5] =
                ENC_R(NOT_OP,6,1,0);

            program_memory[6] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000000);
            check_reg(4,32'h00000FFF);
            check_reg(5,32'h00000FFF);
            check_reg(6,32'hFFFFF555);

        end

    endtask


    // ============================================================
    // TEST 4
    // SHIFTS
    // ============================================================

    task test_shifts;

        begin

            $display("");
            $display("============================================");
            $display("TEST 4: SHIFTS");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h008);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h001);

            program_memory[2] =
                ENC_R(SHL,3,1,2);

            program_memory[3] =
                ENC_R(SHR,4,1,2);

            program_memory[4] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000010);
            check_reg(4,32'h00000004);

        end

    endtask


    // ============================================================
    // TEST 5
    // STORE / LOAD
    // ============================================================

    task test_load_store;

        begin

            $display("");
            $display("============================================");
            $display("TEST 5: LOAD / STORE");
            $display("============================================");

            clear_program;
            clear_data_memory;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h555);

            program_memory[1] =
                ENC_I(STORE,1,0,12'h100);

            program_memory[2] =
                ENC_I(LOAD,2,0,12'h100);

            program_memory[3] =
                ENC_I(MOV,4,2,12'h000);

            program_memory[4] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_memory(12'h100,32'h00000555);
            check_reg(2,32'h00000555);
            check_reg(4,32'h00000555);

        end

    endtask


    // ============================================================
    // TEST 6
    // CMP + BEQ
    // ============================================================

    task test_cmp_beq;

        begin

            $display("");
            $display("============================================");
            $display("TEST 6: CMP + BEQ");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h005);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BEQ,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);
            check_psr(4'b0101);

        end

    endtask


    // ============================================================
    // TEST 7
    // BNE
    // ============================================================

    task test_bne;

        begin

            $display("");
            $display("============================================");
            $display("TEST 7: BNE");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h006);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BNE,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 8
    // JMP
    // ============================================================

    task test_jmp;

        begin

            $display("");
            $display("============================================");
            $display("TEST 8: JMP");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_J(JMP,12'h004);

            program_memory[1] =
                ENC_I(LOAD_IMM,1,0,12'h111);

            program_memory[2] =
                ENC_I(LOAD_IMM,1,0,12'h111);

            program_memory[3] =
                ENC_I(LOAD_IMM,1,0,12'h111);

            program_memory[4] =
                ENC_I(LOAD_IMM,1,0,12'h222);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 9
    // JMP_IF
    // ============================================================

    task test_jmp_if;

        begin

            $display("");
            $display("============================================");
            $display("TEST 9: JMP_IF");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(JMP_IF,0,1,12'h004);

            program_memory[2] =
                ENC_I(LOAD_IMM,2,0,12'h111);

            program_memory[3] =
                ENC_J(JMP,12'h005);

            program_memory[4] =
                ENC_I(LOAD_IMM,2,0,12'h222);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 10
    // EQ / SLT / SLTU
    // ============================================================

    task test_comparisons;

        begin

            $display("");
            $display("============================================");
            $display("TEST 10: EQ / SLT / SLTU");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(EQ,3,1,1);

            program_memory[3] =
                ENC_R(SLT,5,1,2);

            program_memory[4] =
                ENC_R(SLTU,6,1,2);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000001);
            check_reg(5,32'h00000001);
            check_reg(6,32'h00000001);

        end

    endtask


    // ============================================================
    // TEST 11
    // LUI
    // ============================================================

    task test_lui;

        begin

            $display("");
            $display("============================================");
            $display("TEST 11: LUI");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LUI,1,0,12'h123);

            program_memory[1] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'h12300000);

        end

    endtask


    // ============================================================
    // TEST 12
    // HALT
    // ============================================================

    task test_halt;

        reg [PROG_ADDR_WIDTH-1:0] saved_pc;

        begin

            $display("");
            $display("============================================");
            $display("TEST 12: HALT");
            $display("============================================");

            clear_program;

            program_memory[0] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            saved_pc = pc;

            repeat (10)
                @(posedge clk);

            if (pc === saved_pc) begin

                $display("PASS: PC remains unchanged in HLT");
                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: PC changed in HLT: 0x%03h -> 0x%03h",
                    saved_pc,
                    pc
                );

                failed = failed + 1;

            end

            if (dut.present_state === HLT_STATE) begin

                $display("PASS: CPU remains in HLT");
                passed = passed + 1;

            end
            else begin

                $display("FAIL: CPU left HLT state");
                failed = failed + 1;

            end

        end

    endtask


    // ============================================================
    // TEST 13
    // NOP
    // ============================================================

    task test_nop;

        begin

            $display("");
            $display("============================================");
            $display("TEST 13: NOP");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h111);

            program_memory[1] =
                ENC_R(NOP,0,0,0);

            program_memory[2] =
                ENC_I(LOAD_IMM,2,0,12'h222);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'h00000111);
            check_reg(2,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 14
    // XOR
    // ============================================================

    task test_xor;

        begin

            $display("");
            $display("============================================");
            $display("TEST 14: XOR");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hAAA);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h555);

            program_memory[2] =
                ENC_R(XOR_OP,3,1,2);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000FFF);

        end

    endtask


    // ============================================================
    // TEST 15
    // ROL
    // ============================================================

    task test_rol;

        begin

            $display("");
            $display("============================================");
            $display("TEST 15: ROL");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h001);

            program_memory[2] =
                ENC_R(ROL,3,1,2);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000002);

        end

    endtask


    // ============================================================
    // TEST 16
    // ROR
    // ============================================================

    task test_ror;

        begin

            $display("");
            $display("============================================");
            $display("TEST 16: ROR");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h001);

            program_memory[2] =
                ENC_R(ROR,3,1,2);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h80000000);

        end

    endtask


    // ============================================================
    // TEST 17
    // SAR
    // ============================================================

    task test_sar;

        begin

            $display("");
            $display("============================================");
            $display("TEST 17: SAR");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h800);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h001);

            program_memory[2] =
                ENC_R(SAR,3,1,2);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000400);

        end

    endtask


    // ============================================================
    // TEST 18
    // ADDI
    // ============================================================

    task test_addi;

        begin

            $display("");
            $display("============================================");
            $display("TEST 18: ADDI");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h100);

            program_memory[1] =
                ENC_I(ADDI,2,1,12'h010);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h00000110);

        end

    endtask


    // ============================================================
    // TEST 19
    // SUBI
    // ============================================================

    task test_subi;

        begin

            $display("");
            $display("============================================");
            $display("TEST 19: SUBI");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h100);

            program_memory[1] =
                ENC_I(SUBI,2,1,12'h010);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h000000F0);

        end

    endtask


    // ============================================================
    // TEST 20
    // ANDI
    // ============================================================

    task test_andi;

        begin

            $display("");
            $display("============================================");
            $display("TEST 20: ANDI");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hFFF);

            program_memory[1] =
                ENC_I(ANDI,2,1,12'h0F0);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h000000F0);

        end

    endtask


    // ============================================================
    // TEST 21
    // ORI
    // ============================================================

    task test_ori;

        begin

            $display("");
            $display("============================================");
            $display("TEST 21: ORI");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hF00);

            program_memory[1] =
                ENC_I(ORI,2,1,12'h0FF);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h00000FFF);

        end

    endtask


    // ============================================================
    // TEST 22
    // XORI
    // ============================================================

    task test_xori;

        begin

            $display("");
            $display("============================================");
            $display("TEST 22: XORI");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hAAA);

            program_memory[1] =
                ENC_I(XORI,2,1,12'h0FF);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h00000A55);

        end

    endtask


    // ============================================================
    // TEST 23
    // CMP
    // ============================================================

    task test_cmp;

        begin

            $display("");
            $display("============================================");
            $display("TEST 23: CMP FLAGS");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h005);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_psr(4'b0101);

        end

    endtask


    // ============================================================
    // TEST 24
    // BEQ TAKEN
    // ============================================================

    task test_beq;

        begin

            $display("");
            $display("============================================");
            $display("TEST 24: BEQ");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h005);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BEQ,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 25
    // BNE TAKEN
    // ============================================================

    task test_bne_extended;

        begin

            $display("");
            $display("============================================");
            $display("TEST 25: BNE");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h006);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BNE,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 26
    // BLT
    // ============================================================

    task test_blt;

        begin

            $display("");
            $display("============================================");
            $display("TEST 26: BLT");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BLT,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 27
    // BGE
    // ============================================================

    task test_bge;

        begin

            $display("");
            $display("============================================");
            $display("TEST 27: BGE");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BGE,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 28
    // BLTU
    // ============================================================

    task test_bltu;

        begin

            $display("");
            $display("============================================");
            $display("TEST 28: BLTU");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BLTU,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 29
    // BGEU
    // ============================================================

    task test_bgeu;

        begin

            $display("");
            $display("============================================");
            $display("TEST 29: BGEU");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(CMP,0,1,2);

            program_memory[3] =
                ENC_J(BGEU,12'h006);

            program_memory[4] =
                ENC_I(LOAD_IMM,3,0,12'h111);

            program_memory[5] =
                ENC_J(JMP,12'h007);

            program_memory[6] =
                ENC_I(LOAD_IMM,3,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 30
    // JMP_REG
    // ============================================================

    task test_jmp_reg;

        begin

            $display("");
            $display("============================================");
            $display("TEST 30: JMP_REG");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h006);

            program_memory[1] =
                ENC_R(JMP_REG,0,1,0);

            program_memory[2] =
                ENC_I(LOAD_IMM,2,0,12'h111);

            program_memory[3] =
                ENC_I(LOAD_IMM,2,0,12'h111);

            program_memory[4] =
                ENC_I(LOAD_IMM,2,0,12'h111);

            program_memory[5] =
                ENC_I(LOAD_IMM,2,0,12'h111);

            program_memory[6] =
                ENC_I(LOAD_IMM,2,0,12'h222);

            program_memory[7] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(2,32'h00000222);

        end

    endtask


    // ============================================================
    // TEST 31
    // INDIRECT LOAD / STORE
    // ============================================================

    task test_indirect_memory;

        begin

            $display("");
            $display("============================================");
            $display("TEST 31: LOAD_IND / STORE_IND");
            $display("============================================");

            clear_program;
            clear_data_memory;

            /*
             * R1 = address
             * R2 = data
             *
             * STORE_IND:
             *
             *   address = R[rs2]
             *   data    = R[rd]
             *
             * therefore:
             *
             *   ENC_R(STORE_IND,2,0,1)
             *
             * means:
             *
             *   MEM[R1] = R2
             */

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h120);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h555);

            program_memory[2] =
                ENC_R(STORE_IND,2,0,1);

            /*
             * LOAD_IND:
             *
             *   address = R[rs1]
             *   destination = R[rd]
             *
             * therefore:
             *
             *   ENC_R(LOAD_IND,3,1,0)
             *
             * means:
             *
             *   R3 = MEM[R1]
             */

            program_memory[3] =
                ENC_R(LOAD_IND,3,1,0);

            program_memory[4] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_memory(12'h120,32'h00000555);
            check_reg(3,32'h00000555);

        end

    endtask


    // ============================================================
    // TEST 32
    // MEMORY BOUNDARIES
    // ============================================================

    task test_memory_boundaries;

        begin

            $display("");
            $display("============================================");
            $display("TEST 32: MEMORY BOUNDARY ADDRESSES");
            $display("============================================");

            clear_program;
            clear_data_memory;

            data_memory[0] =
                32'hAAAAAAAA;

            data_memory[12'hFFF] =
                32'h55555555;

            program_memory[0] =
                ENC_I(LOAD,1,0,12'h000);

            program_memory[1] =
                ENC_I(LOAD,2,0,12'hFFF);

            program_memory[2] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'hAAAAAAAA);
            check_reg(2,32'h55555555);

        end

    endtask


    // ============================================================
    // TEST 33
    // RESET
    // ============================================================

    task test_reset;

        begin

            $display("");
            $display("============================================");
            $display("TEST 33: RESET");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h123);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h456);

            program_memory[2] =
                {HALT,24'b0};

            /*
             * Assert reset.
             */

            rst_n = 1'b0;

            repeat (4)
                @(posedge clk);

            if (pc === 12'd0) begin

                $display("PASS: PC reset to 0");
                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: PC expected 0, got %0d",
                    pc
                );

                failed = failed + 1;

            end

            /*
             * Release reset and allow program to run.
             */

            rst_n = 1'b1;

            wait_for_halt;

            check_reg(1,32'h00000123);
            check_reg(2,32'h00000456);

        end

    endtask


    // ============================================================
    // TEST 34
    // ALU EDGE VALUES
    // ============================================================

    task test_alu_edges;

        begin

            $display("");
            $display("============================================");
            $display("TEST 34: ALU EDGE CASES");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'hFFF);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h001);

            program_memory[2] =
                ENC_R(ADD,3,1,2);

            program_memory[3] =
                ENC_R(SUB,4,1,2);

            program_memory[4] =
                ENC_R(MUL,5,1,2);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00001000);
            check_reg(4,32'h00000FFE);
            check_reg(5,32'h00000FFF);

        end

    endtask


    // ============================================================
    // TEST 35
    // EQ
    // ============================================================

    task test_eq;

        begin

            $display("");
            $display("============================================");
            $display("TEST 35: EQ");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h005);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h005);

            program_memory[2] =
                ENC_R(EQ,3,1,2);

            program_memory[3] =
                ENC_I(LOAD_IMM,4,0,12'h006);

            program_memory[4] =
                ENC_R(EQ,5,1,4);

            program_memory[5] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000001);
            check_reg(5,32'h00000000);

        end

    endtask


    // ============================================================
    // TEST 36
    // SLT
    // ============================================================

    task test_slt;

        begin

            $display("");
            $display("============================================");
            $display("TEST 36: SLT");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(SLT,3,1,2);

            program_memory[3] =
                ENC_R(SLT,4,2,1);

            program_memory[4] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000001);
            check_reg(4,32'h00000000);

        end

    endtask


    // ============================================================
    // TEST 37
    // SLTU
    // ============================================================

    task test_sltu;

        begin

            $display("");
            $display("============================================");
            $display("TEST 37: SLTU");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LOAD_IMM,1,0,12'h001);

            program_memory[1] =
                ENC_I(LOAD_IMM,2,0,12'h002);

            program_memory[2] =
                ENC_R(SLTU,3,1,2);

            program_memory[3] =
                ENC_R(SLTU,4,2,1);

            program_memory[4] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(3,32'h00000001);
            check_reg(4,32'h00000000);

        end

    endtask


    // ============================================================
    // TEST 38
    // LUI
    // ============================================================

    task test_lui_extended;

        begin

            $display("");
            $display("============================================");
            $display("TEST 38: LUI");
            $display("============================================");

            clear_program;

            program_memory[0] =
                ENC_I(LUI,1,0,12'h123);

            program_memory[1] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            check_reg(1,32'h12300000);

        end

    endtask


    // ============================================================
    // TEST 39
    // HALT
    // ============================================================

    task test_halt_again;

        reg [PROG_ADDR_WIDTH-1:0] saved_pc;

        begin

            $display("");
            $display("============================================");
            $display("TEST 39: HALT");

            clear_program;

            program_memory[0] =
                {HALT,24'b0};

            reset_cpu;
            wait_for_halt;

            saved_pc = pc;

            repeat (10)
                @(posedge clk);

            if (pc === saved_pc) begin

                $display("PASS: PC remains unchanged in HLT");
                passed = passed + 1;

            end
            else begin

                $display(
                    "FAIL: PC changed during HLT"
                );

                failed = failed + 1;

            end

            if (dut.present_state === HLT_STATE) begin

                $display("PASS: CPU remains in HLT");
                passed = passed + 1;

            end
            else begin

                $display("FAIL: CPU left HLT");
                failed = failed + 1;

            end

        end

    endtask


    // ============================================================
    // WAVEFORM
    // ============================================================

    initial begin

        $dumpfile("cpu_core_tb.vcd");
        $dumpvars(0,cpu_core_tb);

    end


    // ============================================================
    // OPTIONAL LIVE DEBUG
    // ============================================================

    /*
     * Uncomment this block if a test hangs.
     *
     * It prints the CPU state every clock.
     */

    /*
    always @(posedge clk) begin

        if (rst_n) begin

            $display(
                "T=%0t PC=%03h IR=%08h OP=%02h STATE=%0d NEXT=%0d REQ=%b RW=%b ADDR=%04h RDATA=%08h READY=%b",
                $time,
                pc,
                dut.instruction_reg,
                dut.opcode,
                dut.present_state,
                dut.next_state,
                cpu_req,
                read_write,
                addr,
                rdata,
                cpu_ready
            );

        end

    end
    */


    // ============================================================
    // MAIN TEST SEQUENCE
    // ============================================================

    initial begin

        passed = 0;
        failed = 0;

        rst_n = 1'b0;

        rdata_reg     = 32'b0;
        cpu_ready_reg = 1'b0;

        clear_program;
        clear_data_memory;

        $display("");
        $display("============================================");
        $display("        CPU LITE CPU CORE TESTBENCH");
        $display("============================================");

        // --------------------------------------------------------
        // BASIC INSTRUCTIONS
        // --------------------------------------------------------

        test_load_imm_mov;
        test_arithmetic;
        test_logical;
        test_shifts;
        test_load_store;
        test_cmp_beq;
        test_bne;
        test_jmp;
        test_jmp_if;
        test_comparisons;
        test_lui;
        test_halt;

        // --------------------------------------------------------
        // EXTENDED INSTRUCTIONS
        // --------------------------------------------------------

        test_nop;
        test_xor;
        test_rol;
        test_ror;
        test_sar;

        test_addi;
        test_subi;
        test_andi;
        test_ori;
        test_xori;

        test_cmp;

        test_beq;
        test_bne_extended;
        test_blt;
        test_bge;
        test_bltu;
        test_bgeu;

        test_jmp_reg;

        test_indirect_memory;
        test_memory_boundaries;

        test_reset;

        test_alu_edges;

        test_eq;
        test_slt;
        test_sltu;

        test_lui_extended;

        test_halt_again;

        // --------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------

        $display("");
        $display("============================================");
        $display("              TEST SUMMARY");
        $display("============================================");

        $display("PASSED = %0d",passed);
        $display("FAILED = %0d",failed);

        $display("============================================");

        if (failed == 0)
            $display("*** ALL CPU CORE TESTS PASSED ***");
        else
            $display("*** CPU CORE TESTS FAILED ***");

        $display("============================================");

        #20;

        $finish;

    end

endmodule

