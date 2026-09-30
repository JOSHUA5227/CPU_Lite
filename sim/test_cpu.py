import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly


# ============================================================
# OPCODES
# ============================================================

OP_NOP       = 0x00
OP_LOAD      = 0x01
OP_LOAD_IND  = 0x02
OP_LOAD_IMM  = 0x03
OP_STORE     = 0x04
OP_STORE_IND = 0x05

OP_ADD       = 0x06
OP_SUB       = 0x07
OP_MUL       = 0x08
OP_AND       = 0x09
OP_OR        = 0x0A
OP_NOT       = 0x0B
OP_CMP       = 0x0C
OP_EQ        = 0x0D

OP_JMP       = 0x0E
OP_JMP_IF    = 0x0F

OP_XOR       = 0x10
OP_SHL       = 0x11
OP_SHR       = 0x12
OP_SAR       = 0x13
OP_ROL       = 0x14
OP_ROR       = 0x15

OP_ADDI      = 0x16
OP_SUBI      = 0x17
OP_ANDI      = 0x18
OP_ORI       = 0x19
OP_XORI      = 0x1A
OP_MOV       = 0x1B
OP_SLT       = 0x1C
OP_SLTU      = 0x1D
OP_LUI       = 0x1E

OP_BEQ       = 0x20
OP_BNE       = 0x21
OP_BLT       = 0x22
OP_BGE       = 0x23
OP_BLTU      = 0x24
OP_BGEU      = 0x25

OP_JMP_REG   = 0x26
OP_CALL      = 0x27
OP_RET       = 0x28

OP_HALT      = 0xFF


# ============================================================
# INSTRUCTION ENCODERS
#
# [31:24] OPCODE
# [23:20] RD / OUT
# [19:16] RS1 / OP1
# [15:12] RS2 / OP2
# [11:0]  IMM / ADDR
# ============================================================

def r_type(op, rd, rs1, rs2):
    return (
        ((op & 0xFF) << 24)
        | ((rd & 0xF) << 20)
        | ((rs1 & 0xF) << 16)
        | ((rs2 & 0xF) << 12)
    )


def i_type(op, rd, rs1, imm):
    return (
        ((op & 0xFF) << 24)
        | ((rd & 0xF) << 20)
        | ((rs1 & 0xF) << 16)
        | (imm & 0xFFF)
    )


def load_imm(rd, imm):
    return i_type(OP_LOAD_IMM, rd, 0, imm)


def load(rd, addr):
    return i_type(OP_LOAD, rd, 0, addr)


def store(rd, addr):
    return i_type(OP_STORE, rd, 0, addr)


def load_ind(rd, rs1):
    return (
        ((OP_LOAD_IND & 0xFF) << 24)
        | ((rd & 0xF) << 20)
        | ((rs1 & 0xF) << 16)
    )


def store_ind(rd, rs2):
    return (
        ((OP_STORE_IND & 0xFF) << 24)
        | ((rd & 0xF) << 20)
        | ((rs2 & 0xF) << 12)
    )


def jmp(addr):
    return ((OP_JMP & 0xFF) << 24) | (addr & 0xFFF)


def jmp_if(rs1, addr):
    return (
        ((OP_JMP_IF & 0xFF) << 24)
        | ((rs1 & 0xF) << 16)
        | (addr & 0xFFF)
    )


def branch(op, addr):
    return ((op & 0xFF) << 24) | (addr & 0xFFF)


def jmp_reg(rs1):
    return (
        ((OP_JMP_REG & 0xFF) << 24)
        | ((rs1 & 0xF) << 16)
    )


# ============================================================
# CALL / RET
#
# CALL:
#   stack[SP] = PC
#   SP = SP - 1
#   PC = immediate address
#
# RET:
#   PC = stack[SP + 1]
#   SP = SP + 1
# ============================================================

def call(addr):
    return (
        ((OP_CALL & 0xFF) << 24)
        | (addr & 0xFFF)
    )


def ret():
    return (
        (OP_RET & 0xFF) << 24
    )


def halt():
    return 0xFF000000


def make_u32(rd, value):
    """
    Construct an arbitrary 32-bit constant using the CPU ISA.

    LUI supplies bits [31:20].
    The middle byte [19:12] is generated in a scratch register.
    ORI supplies bits [11:0].

    Scratch registers 14 and 15 are reserved by this helper.
    """

    value &= 0xFFFFFFFF

    hi = (value >> 20) & 0xFFF
    mid = (value >> 12) & 0xFF
    lo = value & 0xFFF

    scratch = 14
    shift_reg = 15

    return [
        i_type(OP_LUI, rd, 0, hi),
        load_imm(scratch, mid),
        load_imm(shift_reg, 12),
        r_type(OP_SHL, scratch, scratch, shift_reg),
        r_type(OP_OR, rd, rd, scratch),
        i_type(OP_ORI, rd, rd, lo),
    ]


def get_psr(dut):
    return int(cpu_core(dut).psr.value)


# ============================================================
# DUT HELPERS
# ============================================================

def cpu_core(dut):
    return dut.u_cpu_core


def program_memory(dut):
    return dut.u_program_memory


def data_memory(dut):
    return dut.u_data_memory


def get_reg(dut, index):
    return int(cpu_core(dut).R[index].value)


def get_pc(dut):
    return int(cpu_core(dut).pc.value)


def get_state(dut):
    return int(cpu_core(dut).present_state.value)


def get_ir(dut):
    return int(cpu_core(dut).instruction_reg.value)


def get_stack_pointer(dut):
    return int(cpu_core(dut).stack_pointer.value)


def get_data_mem(dut, addr):
    return int(data_memory(dut).mem[addr].value)


# ============================================================
# CLOCKS
# ============================================================

async def start_clocks(dut):

    cocotb.start_soon(
        Clock(dut.fast_clk, 6.666, units="ns").start()
    )

    cocotb.start_soon(
        Clock(dut.slow_clk, 14.286, units="ns").start()
    )


# ============================================================
# MEMORY INITIALIZATION
# ============================================================

def clear_program(dut, count=64):

    pmem = program_memory(dut)

    for i in range(count):
        pmem.mem[i].value = 0


def clear_data_memory(dut, count=512):

    dmem = data_memory(dut)

    for i in range(count):
        dmem.mem[i].value = 0


def load_program(dut, program):

    pmem = program_memory(dut)

    for address, instruction in enumerate(program):
        pmem.mem[address].value = instruction & 0xFFFFFFFF


# ============================================================
# RESET / TEST SETUP
# ============================================================

async def assert_reset(dut):

    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0

    for _ in range(8):
        await RisingEdge(dut.fast_clk)

    for _ in range(4):
        await RisingEdge(dut.slow_clk)


async def release_reset(dut):

    await RisingEdge(dut.fast_clk)
    await RisingEdge(dut.slow_clk)

    dut.fast_rst_n.value = 1
    dut.slow_rst_n.value = 1

    for _ in range(3):
        await RisingEdge(dut.fast_clk)


async def prepare_test(dut, program, memory_init=None):

    await Timer(1, unit="ns")

    await assert_reset(dut)

    clear_program(dut)
    clear_data_memory(dut)

    load_program(dut, program)

    if memory_init is not None:

        for addr, value in memory_init.items():
            data_memory(dut).mem[addr].value = value & 0xFFFFFFFF

    for _ in range(3):
        await RisingEdge(dut.fast_clk)

    await release_reset(dut)


# ============================================================
# HALT / TIMEOUT
# ============================================================

async def wait_for_halt(
    dut,
    max_cycles=5000,
    test_name="UNKNOWN"
):

    for cycle in range(max_cycles):

        await RisingEdge(dut.fast_clk)
        await ReadOnly()

        state = get_state(dut)

        # HLT = 7
        if state == 7:
            return True

    print()
    print("==============================================")
    print(f"TIMEOUT: {test_name}")
    print("==============================================")
    print(f"PC    = {get_pc(dut):03X}")
    print(f"STATE = {get_state(dut)}")
    print(f"IR    = {get_ir(dut):08X}")
    print(f"SP    = {get_stack_pointer(dut):04X}")

    for i in range(1, 9):
        print(f"R{i}    = {get_reg(dut, i):08X}")

    return False


# ============================================================
# CHECKING
# ============================================================

class Regression:

    def __init__(self):

        self.total = 0
        self.passed = 0
        self.failed = 0

    def check(self, name, actual, expected):

        self.total += 1

        actual &= 0xFFFFFFFF
        expected &= 0xFFFFFFFF

        if actual == expected:

            self.passed += 1

            print(
                f"    PASS: {name:<24} = {actual:08X}"
            )

        else:

            self.failed += 1

            print(
                f"    FAIL: {name:<24} = {actual:08X} "
                f"expected {expected:08X}"
            )


def test_header(number, name):

    print()
    print("==============================================")
    print(f"TEST {number:02d}: {name}")
    print("==============================================")


# ============================================================
# TEST 01
# BASIC MEMORY
# ============================================================

async def test_basic_memory(dut, reg):

    test_header(1, "BASIC MEMORY")

    program = [
        load_imm(1, 0x555),
        store(1, 0x100),
        load(2, 0x100),
        r_type(OP_ADD, 3, 1, 2),
        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 01"
    )

    reg.check("R1", get_reg(dut, 1), 0x555)
    reg.check("R2", get_reg(dut, 2), 0x555)
    reg.check("R3", get_reg(dut, 3), 0xAAA)
    reg.check("MEM[100]", get_data_mem(dut, 0x100), 0x555)


# ============================================================
# TEST 02
# ALU
# ============================================================

async def test_alu(dut, reg):

    test_header(2, "ALU OPERATIONS")

    program = [
        load_imm(1, 0x00F),
        load_imm(2, 0x003),

        r_type(OP_ADD, 3, 1, 2),
        r_type(OP_SUB, 4, 1, 2),
        r_type(OP_MUL, 5, 1, 2),
        r_type(OP_AND, 6, 1, 2),
        r_type(OP_OR, 7, 1, 2),
        r_type(OP_XOR, 8, 1, 2),
        r_type(OP_NOT, 9, 1, 0),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 02"
    )

    reg.check("ADD", get_reg(dut, 3), 0x12)
    reg.check("SUB", get_reg(dut, 4), 0x0C)
    reg.check("MUL", get_reg(dut, 5), 0x2D)
    reg.check("AND", get_reg(dut, 6), 0x03)
    reg.check("OR", get_reg(dut, 7), 0x0F)
    reg.check("XOR", get_reg(dut, 8), 0x0C)
    reg.check("NOT", get_reg(dut, 9), 0xFFFFFFF0)


# ============================================================
# TEST 03
# IMMEDIATE
# ============================================================

async def test_immediates(dut, reg):

    test_header(3, "IMMEDIATE OPERATIONS")

    program = [
        load_imm(1, 0x00A),
        i_type(OP_ADDI, 2, 1, 0x005),
        i_type(OP_SUBI, 3, 2, 0x003),
        i_type(OP_ANDI, 4, 1, 0x00F),
        i_type(OP_ORI, 5, 1, 0x100),
        i_type(OP_XORI, 6, 1, 0x00F),
        r_type(OP_MOV, 7, 1, 0),
        i_type(OP_LUI, 8, 0, 0x123),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 03"
    )

    reg.check("ADDI", get_reg(dut, 2), 0xF)
    reg.check("SUBI", get_reg(dut, 3), 0xC)
    reg.check("ANDI", get_reg(dut, 4), 0xA)
    reg.check("ORI", get_reg(dut, 5), 0x10A)
    reg.check("XORI", get_reg(dut, 6), 0x5)
    reg.check("MOV", get_reg(dut, 7), 0xA)
    reg.check("LUI", get_reg(dut, 8), 0x12300000)


# ============================================================
# TEST 04
# SHIFTS / ROTATES
# ============================================================

async def test_shifts(dut, reg):

    test_header(4, "SHIFTS / ROTATES")

    program = [
        i_type(OP_LUI, 1, 0, 0x800),
        i_type(OP_ORI, 1, 1, 0x001),

        load_imm(2, 1),

        r_type(OP_SHL, 3, 1, 2),
        r_type(OP_SHR, 4, 1, 2),
        r_type(OP_SAR, 5, 1, 2),
        r_type(OP_ROL, 6, 1, 2),
        r_type(OP_ROR, 7, 1, 2),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 04"
    )

    reg.check("SHL", get_reg(dut, 3), 0x00000002)
    reg.check("SHR", get_reg(dut, 4), 0x40000000)
    reg.check("SAR", get_reg(dut, 5), 0xC0000000)
    reg.check("ROL", get_reg(dut, 6), 0x00000003)
    reg.check("ROR", get_reg(dut, 7), 0xC0000000)


# ============================================================
# TEST 05
# COMPARISON
# ============================================================

async def test_compare(dut, reg):

    test_header(5, "COMPARISON / FLAGS")

    program = [
        load_imm(1, 5),
        load_imm(2, 5),

        r_type(OP_CMP, 0, 1, 2),
        r_type(OP_EQ, 3, 1, 2),

        load_imm(4, 3),
        load_imm(5, 7),

        r_type(OP_SLT, 6, 4, 5),
        r_type(OP_SLTU, 7, 4, 5),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 05"
    )

    reg.check("EQ", get_reg(dut, 3), 1)
    reg.check("SLT", get_reg(dut, 6), 1)
    reg.check("SLTU", get_reg(dut, 7), 1)


# ============================================================
# TEST 06
# BEQ
# ============================================================

async def test_beq(dut, reg):

    test_header(6, "BEQ")

    program = [
        load_imm(1, 5),
        load_imm(2, 5),
        r_type(OP_CMP, 0, 1, 2),
        branch(OP_BEQ, 6),

        load_imm(3, 0x999),
        load_imm(3, 0x888),
        load_imm(3, 0x123),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 06"
    )

    reg.check("BEQ target", get_reg(dut, 3), 0x123)


# ============================================================
# TEST 07
# BNE
# ============================================================

async def test_bne(dut, reg):

    test_header(7, "BNE")

    program = [
        load_imm(1, 5),
        load_imm(2, 7),
        r_type(OP_CMP, 0, 1, 2),
        branch(OP_BNE, 6),

        load_imm(3, 0x999),
        load_imm(3, 0x888),
        load_imm(3, 0x321),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 07"
    )

    reg.check("BNE target", get_reg(dut, 3), 0x321)


# ============================================================
# TEST 08
# SIGNED / UNSIGNED BRANCHES
# ============================================================

async def test_signed_unsigned_branches(dut, reg):

    test_header(8, "SIGNED / UNSIGNED BRANCHES")

    program = [
        i_type(OP_LUI, 1, 0, 0xFFF),
        i_type(OP_ORI, 1, 1, 0xFFF),

        load_imm(2, 1),

        r_type(OP_CMP, 0, 1, 2),
        branch(OP_BLT, 7),

        load_imm(3, 0xBAD),
        jmp(8),

        load_imm(3, 0x111),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 08"
    )

    reg.check("BLT", get_reg(dut, 3), 0x111)


# ============================================================
# TEST 09
# JUMPS
# ============================================================

async def test_jumps(dut, reg):

    test_header(9, "JUMPS")

    program = [
        jmp(3),

        load_imm(1, 0x111),
        load_imm(1, 0x222),
        load_imm(1, 0x333),

        i_type(OP_ADDI, 1, 1, 1),

        jmp_if(1, 7),

        load_imm(2, 0xBAD),
        load_imm(2, 0x444),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 09"
    )

    reg.check("JMP", get_reg(dut, 1), 0x334)
    reg.check("JMP_IF", get_reg(dut, 2), 0x444)


# ============================================================
# TEST 10
# INDIRECT MEMORY
# ============================================================

async def test_indirect_memory(dut, reg):

    test_header(10, "INDIRECT MEMORY")

    program = [
        load_imm(1, 0x200),
        load_imm(2, 0x123),

        store_ind(2, 1),
        load_ind(3, 1),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 10"
    )

    reg.check(
        "IND STORE",
        get_data_mem(dut, 0x200),
        0x123
    )

    reg.check(
        "IND LOAD",
        get_reg(dut, 3),
        0x123
    )


# ============================================================
# TEST 11
# CACHE LINE
# ============================================================

async def test_cache_line(dut, reg):

    test_header(11, "CACHE LINE ACCESS")

    program = [
        load(1, 0x100),
        load(2, 0x101),
        load(3, 0x102),
        load(4, 0x103),

        halt(),
    ]

    memory = {
        0x100: 0x11111111,
        0x101: 0x22222222,
        0x102: 0x33333333,
        0x103: 0x44444444,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        test_name="TEST 11"
    )

    reg.check("LINE WORD 0", get_reg(dut, 1), 0x11111111)
    reg.check("LINE WORD 1", get_reg(dut, 2), 0x22222222)
    reg.check("LINE WORD 2", get_reg(dut, 3), 0x33333333)
    reg.check("LINE WORD 3", get_reg(dut, 4), 0x44444444)


# ============================================================
# TEST 12
# CACHE CONFLICT
# ============================================================

async def test_cache_conflict(dut, reg):

    test_header(12, "CACHE CONFLICT")

    program = [
        load(1, 0x100),
        load(2, 0x120),
        load(3, 0x100),
        load(4, 0x120),

        halt(),
    ]

    memory = {
        0x100: 0xAAAAAAAA,
        0x120: 0xBBBBBBBB,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        test_name="TEST 12"
    )

    reg.check(
        "CONFLICT A",
        get_reg(dut, 1),
        0xAAAAAAAA
    )

    reg.check(
        "CONFLICT B",
        get_reg(dut, 2),
        0xBBBBBBBB
    )

    reg.check(
        "RELOAD A",
        get_reg(dut, 3),
        0xAAAAAAAA
    )

    reg.check(
        "RELOAD B",
        get_reg(dut, 4),
        0xBBBBBBBB
    )


# ============================================================
# TEST 13
# RESET
# ============================================================

async def test_reset(dut, reg):

    test_header(13, "RESET")

    program = [
        load_imm(1, 0x555),
        load_imm(2, 0xAAA),
        halt(),
    ]

    await prepare_test(dut, program)

    for _ in range(10):
        await RisingEdge(dut.fast_clk)

    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0

    for _ in range(6):
        await RisingEdge(dut.fast_clk)

    await ReadOnly()

    reg.check("RESET R1", get_reg(dut, 1), 0)
    reg.check("RESET R2", get_reg(dut, 2), 0)
    reg.check("RESET PC", get_pc(dut), 0)

    await release_reset(dut)

    assert await wait_for_halt(
        dut,
        test_name="TEST 13 POST RESET"
    )

    reg.check(
        "POST RESET R1",
        get_reg(dut, 1),
        0x555
    )

    reg.check(
        "POST RESET R2",
        get_reg(dut, 2),
        0xAAA
    )


# ============================================================
# TEST 14
# BOUNDARY VALUES
# ============================================================

async def test_boundaries(dut, reg):

    test_header(14, "BOUNDARY VALUES")

    program = [
        load_imm(1, 0),
        load_imm(2, 1),

        i_type(OP_LUI, 3, 0, 0x7FF),

        load_imm(7, 0xFFF),
        load_imm(8, 8),

        r_type(OP_SHL, 7, 7, 8),

        i_type(OP_ORI, 7, 7, 0xFFF),

        r_type(OP_OR, 3, 3, 7),

        i_type(OP_LUI, 4, 0, 0x800),

        i_type(OP_ADDI, 5, 3, 1),
        i_type(OP_SUBI, 6, 4, 1),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 14"
    )

    reg.check("ZERO", get_reg(dut, 1), 0)
    reg.check("ONE", get_reg(dut, 2), 1)
    reg.check("MAX SIGNED", get_reg(dut, 3), 0x7FFFFFFF)
    reg.check("MIN SIGNED", get_reg(dut, 4), 0x80000000)
    reg.check("MAX + 1", get_reg(dut, 5), 0x80000000)
    reg.check("MIN - 1", get_reg(dut, 6), 0x7FFFFFFF)


# ============================================================
# TEST 15
# LONG MIXED PROGRAM
# ============================================================

async def test_long_program(dut, reg):

    test_header(15, "LONG MIXED PROGRAM")

    program = [
        load_imm(1, 0x100),
        load_imm(2, 4),
        load_imm(3, 0),
        load_imm(4, 0),

        r_type(OP_CMP, 0, 4, 2),
        branch(OP_BGE, 11),

        r_type(OP_ADD, 5, 1, 4),
        load_ind(6, 5),
        r_type(OP_ADD, 3, 3, 6),

        i_type(OP_ADDI, 4, 4, 1),

        jmp(4),

        store(3, 0x200),
        halt(),
    ]

    memory = {
        0x100: 1,
        0x101: 2,
        0x102: 3,
        0x103: 4,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        test_name="TEST 15"
    )

    for _ in range(8):
        await RisingEdge(dut.slow_clk)

    reg.check("LOOP SUM R3", get_reg(dut, 3), 10)
    reg.check("LOOP INDEX R4", get_reg(dut, 4), 4)
    reg.check("MEM[200]", get_data_mem(dut, 0x200), 10)


# ============================================================
# TEST 16
# ARITHMETIC CORNER CASES
# ============================================================

async def test_arithmetic_corner_cases(dut, reg):

    test_header(16, "ARITHMETIC CORNER CASES")

    program = []

    program += make_u32(1, 0xFFFFFFFF)
    program += make_u32(2, 0x00000001)
    program += make_u32(3, 0x7FFFFFFF)
    program += make_u32(4, 0x80000000)

    program += [
        r_type(OP_ADD, 5, 1, 2),
        r_type(OP_ADD, 6, 3, 2),
        r_type(OP_SUB, 7, 0, 2),
        r_type(OP_SUB, 8, 4, 2),
        r_type(OP_MUL, 9, 3, 2),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 16"
    )

    reg.check("ADD carry", get_reg(dut, 5), 0x00000000)
    reg.check("ADD overflow", get_reg(dut, 6), 0x80000000)
    reg.check("SUB borrow", get_reg(dut, 7), 0xFFFFFFFF)
    reg.check("SUB boundary", get_reg(dut, 8), 0x7FFFFFFF)
    reg.check("MUL boundary", get_reg(dut, 9), 0x7FFFFFFF)


# ============================================================
# TEST 17
# IMMEDIATE SIGN / ZERO EXTENSION
# ============================================================

async def test_immediate_boundaries(dut, reg):

    test_header(17, "IMMEDIATE BOUNDARIES")

    program = [
        load_imm(1, 0xFFF),
        i_type(OP_ADDI, 2, 0, 0xFFF),
        i_type(OP_SUBI, 3, 0, 0x001),
        i_type(OP_ANDI, 4, 1, 0xFFF),
        i_type(OP_ORI, 5, 0, 0x800),
        i_type(OP_XORI, 6, 0, 0xFFF),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 17"
    )

    reg.check(
        "LOAD_IMM FFF",
        get_reg(dut, 1),
        0x00000FFF
    )

    reg.check(
        "ADDI -1",
        get_reg(dut, 2),
        0xFFFFFFFF
    )

    reg.check(
        "SUBI 1",
        get_reg(dut, 3),
        0xFFFFFFFF
    )

    reg.check(
        "ANDI FFF",
        get_reg(dut, 4),
        0x00000FFF
    )

    reg.check(
        "ORI 800",
        get_reg(dut, 5),
        0x00000800
    )

    reg.check(
        "XORI FFF",
        get_reg(dut, 6),
        0x00000FFF
    )


# ============================================================
# TEST 18
# SHIFT / ROTATE BOUNDARIES
# ============================================================

async def test_shift_rotate_boundaries(dut, reg):

    test_header(18, "SHIFT / ROTATE BOUNDARIES")

    program = []

    program += make_u32(1, 0x80000001)

    program += [
        load_imm(2, 0),
        load_imm(3, 31),

        r_type(OP_SHL, 4, 1, 2),
        r_type(OP_SHL, 5, 1, 3),

        r_type(OP_SHR, 6, 1, 2),
        r_type(OP_SHR, 7, 1, 3),

        r_type(OP_SAR, 8, 1, 2),
        r_type(OP_SAR, 9, 1, 3),

        r_type(OP_ROL, 10, 1, 2),
        r_type(OP_ROL, 11, 1, 3),

        r_type(OP_ROR, 12, 1, 2),
        r_type(OP_ROR, 13, 1, 3),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 18"
    )

    reg.check("SHL 0", get_reg(dut, 4), 0x80000001)
    reg.check("SHL 31", get_reg(dut, 5), 0x80000000)
    reg.check("SHR 0", get_reg(dut, 6), 0x80000001)
    reg.check("SHR 31", get_reg(dut, 7), 0x00000001)
    reg.check("SAR 0", get_reg(dut, 8), 0x80000001)
    reg.check("SAR 31", get_reg(dut, 9), 0xFFFFFFFF)
    reg.check("ROL 0", get_reg(dut, 10), 0x80000001)
    reg.check("ROL 31", get_reg(dut, 11), 0xC0000000)
    reg.check("ROR 0", get_reg(dut, 12), 0x80000001)
    reg.check("ROR 31", get_reg(dut, 13), 0x00000003)


# ============================================================
# TEST 19
# SIGNED / UNSIGNED COMPARISON CORNERS
# ============================================================

async def test_signed_unsigned_compare(dut, reg):

    test_header(19, "SIGNED / UNSIGNED COMPARISONS")

    program = []

    program += make_u32(1, 0xFFFFFFFF)
    program += make_u32(2, 0x00000001)
    program += make_u32(3, 0x80000000)
    program += make_u32(4, 0x7FFFFFFF)

    program += [
        r_type(OP_SLT, 5, 1, 2),
        r_type(OP_SLTU, 6, 1, 2),

        r_type(OP_SLT, 7, 3, 4),
        r_type(OP_SLTU, 8, 3, 4),

        r_type(OP_EQ, 9, 1, 1),
        r_type(OP_EQ, 10, 1, 2),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 19"
    )

    reg.check("SLT -1 < 1", get_reg(dut, 5), 1)
    reg.check("SLTU FFFF < 1", get_reg(dut, 6), 0)
    reg.check("SLT MIN < MAX", get_reg(dut, 7), 1)
    reg.check("SLTU 8000 < 7FFF", get_reg(dut, 8), 0)
    reg.check("EQ same", get_reg(dut, 9), 1)
    reg.check("EQ different", get_reg(dut, 10), 0)


# ============================================================
# TEST 20
# ALL CONDITIONAL BRANCHES
# ============================================================

async def test_all_branches(dut, reg):

    test_header(20, "ALL CONDITIONAL BRANCHES")

    cases = [

        (
            "BEQ",
            [
                load_imm(1, 5),
                load_imm(2, 5),
                r_type(OP_CMP, 0, 1, 2),
                branch(OP_BEQ, 6),
                load_imm(3, 0xBAD),
                jmp(7),
                load_imm(3, 0x111),
                halt(),
            ],
            0x111
        ),

        (
            "BNE",
            [
                load_imm(1, 5),
                load_imm(2, 6),
                r_type(OP_CMP, 0, 1, 2),
                branch(OP_BNE, 6),
                load_imm(3, 0xBAD),
                jmp(7),
                load_imm(3, 0x222),
                halt(),
            ],
            0x222
        ),

        (
            "BGE",
            [
                load_imm(1, 5),
                load_imm(2, 5),
                r_type(OP_CMP, 0, 1, 2),
                branch(OP_BGE, 6),
                load_imm(3, 0xBAD),
                jmp(7),
                load_imm(3, 0x333),
                halt(),
            ],
            0x333
        ),

        (
            "BLTU",
            [
                load_imm(1, 1),
                i_type(OP_LUI, 2, 0, 0xFFF),
                i_type(OP_ORI, 2, 2, 0xFFF),
                r_type(OP_CMP, 0, 1, 2),
                branch(OP_BLTU, 8),
                load_imm(3, 0xBAD),
                jmp(9),
                load_imm(3, 0xBAD),
                load_imm(3, 0x444),
                halt(),
            ],
            0x444
        ),

        (
            "BGEU",
            [
                i_type(OP_LUI, 1, 0, 0xFFF),
                i_type(OP_ORI, 1, 1, 0xFFF),
                load_imm(2, 1),
                r_type(OP_CMP, 0, 1, 2),
                branch(OP_BGEU, 8),
                load_imm(3, 0xBAD),
                jmp(9),
                load_imm(3, 0xBAD),
                load_imm(3, 0x555),
                halt(),
            ],
            0x555
        ),
    ]

    for name, program, expected in cases:

        await prepare_test(dut, program)

        assert await wait_for_halt(
            dut,
            test_name=f"TEST 20 {name}"
        )

        reg.check(
            name,
            get_reg(dut, 3),
            expected
        )


# ============================================================
# TEST 21
# JMP_REG
# ============================================================

async def test_jmp_reg(dut, reg):

    test_header(21, "JMP_REG")

    program = [
        load_imm(1, 6),
        jmp_reg(1),

        load_imm(2, 0xBAD),
        load_imm(2, 0xBAD),
        load_imm(2, 0xBAD),
        load_imm(2, 0xBAD),

        load_imm(2, 0x666),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 21"
    )

    reg.check(
        "JMP_REG",
        get_reg(dut, 2),
        0x666
    )


# ============================================================
# TEST 22
# CALL / RET
# ============================================================

async def test_call_ret(dut, reg):

    test_header(22, "CALL / RET")

    STACK_START = 0x3FFF

    program = [

        # ----------------------------------------------------
        # MAIN
        # ----------------------------------------------------

        load_imm(1, 0x111),     # 0
        call(6),                # 1

        # CALL must return here
        load_imm(2, 0x222),     # 2
        halt(),                 # 3

        # These must never execute
        load_imm(15, 0xBAD),    # 4
        load_imm(15, 0xBAD),    # 5

        # ----------------------------------------------------
        # SUBROUTINE
        # ----------------------------------------------------

        load_imm(3, 0x333),     # 6
        ret(),                  # 7
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        max_cycles=10000,
        test_name="TEST 22"
    )

    # --------------------------------------------------------
    # Main executed
    # --------------------------------------------------------

    reg.check(
        "CALL main R1",
        get_reg(dut, 1),
        0x111
    )

    # --------------------------------------------------------
    # Subroutine executed
    # --------------------------------------------------------

    reg.check(
        "CALL sub R3",
        get_reg(dut, 3),
        0x333
    )

    # --------------------------------------------------------
    # RET returned to PC=2
    # --------------------------------------------------------

    reg.check(
        "RET return R2",
        get_reg(dut, 2),
        0x222
    )

    # --------------------------------------------------------
    # IMPORTANT:
    # Do NOT use R15 as a stack-pointer check.
    #
    # R0-R15 are general-purpose registers according to the
    # CPU specification. The stack pointer is checked through
    # the dedicated stack_pointer RTL signal.
    # --------------------------------------------------------

    # --------------------------------------------------------
    # CALL should restore dedicated stack pointer
    #
    # CALL:
    #   stack[SP] = PC
    #   SP = SP - 1
    #
    # RET:
    #   PC = stack[SP + 1]
    #   SP = SP + 1
    # --------------------------------------------------------

    reg.check(
        "CALL RET stack restore",
        get_stack_pointer(dut),
        STACK_START
    )

    # --------------------------------------------------------
    # Verify saved return address
    # --------------------------------------------------------

    reg.check(
        "CALL saved PC",
        get_data_mem(dut, STACK_START),
        0x00000002
    )
# ============================================================
# TEST 23
# NESTED CALL / RET
# ============================================================

async def test_nested_call_ret(dut, reg):

    test_header(23, "NESTED CALL / RET")

    STACK_START = 0x3FFF

    program = [

        # ----------------------------------------------------
        # MAIN
        # ----------------------------------------------------

        load_imm(1, 0x111),     # 0
        call(8),                # 1

        # Must execute after FUNC_A returns
        load_imm(2, 0x222),     # 2
        halt(),                 # 3

        # Padding
        load_imm(15, 0xBAD),    # 4
        load_imm(15, 0xBAD),    # 5
        load_imm(15, 0xBAD),    # 6
        load_imm(15, 0xBAD),    # 7

        # ----------------------------------------------------
        # FUNC_A
        # ----------------------------------------------------

        load_imm(3, 0x333),     # 8
        call(12),               # 9

        # Must execute after FUNC_B returns
        load_imm(4, 0x444),     # 10
        ret(),                  # 11

        # ----------------------------------------------------
        # FUNC_B
        # ----------------------------------------------------

        load_imm(5, 0x555),     # 12
        ret(),                  # 13
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        max_cycles=15000,
        test_name="TEST 23"
    )

    # --------------------------------------------------------
    # MAIN
    # --------------------------------------------------------

    reg.check(
        "NEST MAIN R1",
        get_reg(dut, 1),
        0x111
    )

    # --------------------------------------------------------
    # FUNC_A
    # --------------------------------------------------------

    reg.check(
        "NEST FUNC_A R3",
        get_reg(dut, 3),
        0x333
    )

    # --------------------------------------------------------
    # FUNC_B
    # --------------------------------------------------------

    reg.check(
        "NEST FUNC_B R5",
        get_reg(dut, 5),
        0x555
    )

    # --------------------------------------------------------
    # RET from FUNC_B -> instruction 10
    # --------------------------------------------------------

    reg.check(
        "NEST return A R4",
        get_reg(dut, 4),
        0x444
    )

    # --------------------------------------------------------
    # RET from FUNC_A -> instruction 2
    # --------------------------------------------------------

    reg.check(
        "NEST return MAIN R2",
        get_reg(dut, 2),
        0x222
    )

    # --------------------------------------------------------
    # Do NOT check R15 as SP.
    #
    # R15 is a normal GPR.
    # The padding instructions should be skipped, but R15
    # itself is not the stack pointer.
    # --------------------------------------------------------

    # --------------------------------------------------------
    # Dedicated stack pointer must be restored.
    # --------------------------------------------------------

    reg.check(
        "NEST stack restore",
        get_stack_pointer(dut),
        STACK_START
    )

    # --------------------------------------------------------
    # First CALL:
    #   stack[3FFF] = 1
    #
    # Second CALL:
    #   stack[3FFE] = 9
    # --------------------------------------------------------

    reg.check(
        "NEST saved main PC",
        get_data_mem(dut, STACK_START),
        0x00000002
    )

    reg.check(
        "NEST saved func PC",
        get_data_mem(dut, STACK_START - 1),
        0x0000000A
    )
# ============================================================
# TEST 24
# DIRECT ADDRESS BOUNDARIES
# ============================================================

async def test_direct_memory_boundaries(dut, reg):

    test_header(24, "DIRECT MEMORY BOUNDARIES")

    program = [
        load_imm(1, 0x111),
        load_imm(2, 0x222),

        store(1, 0x000),
        store(2, 0xFFF),

        load(3, 0x000),
        load(4, 0xFFF),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 24"
    )

    reg.check(
        "MEM[000]",
        get_data_mem(dut, 0x000),
        0x111
    )

    reg.check(
        "MEM[FFF]",
        get_data_mem(dut, 0xFFF),
        0x222
    )

    reg.check(
        "LOAD[000]",
        get_reg(dut, 3),
        0x111
    )

    reg.check(
        "LOAD[FFF]",
        get_reg(dut, 4),
        0x222
    )


# ============================================================
# TEST 25
# 14-BIT INDIRECT ADDRESS
# ============================================================

async def test_indirect_address_boundaries(dut, reg):

    test_header(
        25,
        "14-BIT INDIRECT ADDRESS BOUNDARIES"
    )

    program = []

    program += make_u32(1, 0x3FFF)

    program += [
        load_imm(2, 0x5A5),
        store_ind(2, 1),
        load_ind(3, 1),

        halt(),
    ]

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        test_name="TEST 25"
    )

    reg.check(
        "LOAD_IND 3FFF",
        get_reg(dut, 3),
        0x5A5
    )


# ============================================================
# TEST 26
# CACHE / CDC SEQUENTIAL STRESS
# ============================================================

async def test_memory_stress(dut, reg):

    test_header(
        26,
        "CACHE / CDC SEQUENTIAL STRESS"
    )

    program = []

    for i in range(16):

        program.append(
            load_imm(1, i + 1)
        )

        program.append(
            store(1, 0x300 + i)
        )

    for i in range(16):

        program.append(
            load(2, 0x300 + i)
        )

    program.append(halt())

    await prepare_test(dut, program)

    assert await wait_for_halt(
        dut,
        max_cycles=10000,
        test_name="TEST 26"
    )

    for _ in range(20):
        await RisingEdge(dut.slow_clk)

    for i in range(16):

        reg.check(
            f"MEM[{0x300+i:03X}]",
            get_data_mem(dut, 0x300 + i),
            i + 1
        )


# ============================================================
# TEST 27
# MIXED ALU + MEMORY + BRANCH STRESS
# ============================================================

async def test_mixed_stress(dut, reg):

    test_header(
        27,
        "MIXED ALU / MEMORY / BRANCH STRESS"
    )

    program = [
        load_imm(1, 0x380),
        load_imm(2, 8),
        load_imm(3, 0),
        load_imm(4, 0),

        r_type(OP_CMP, 0, 4, 2),
        branch(OP_BGE, 11),

        r_type(OP_ADD, 5, 1, 4),
        load_ind(6, 5),
        r_type(OP_ADD, 3, 3, 6),

        i_type(OP_ADDI, 4, 4, 1),

        jmp(4),

        store(3, 0x390),

        halt(),
    ]

    memory = {
        0x380: 1,
        0x381: 2,
        0x382: 3,
        0x383: 4,
        0x384: 5,
        0x385: 6,
        0x386: 7,
        0x387: 8,
    }

    await prepare_test(
        dut,
        program,
        memory
    )

    assert await wait_for_halt(
        dut,
        max_cycles=10000,
        test_name="TEST 27"
    )

    for _ in range(12):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "SUM",
        get_reg(dut, 3),
        36
    )

    reg.check(
        "INDEX",
        get_reg(dut, 4),
        8
    )

    reg.check(
        "MEM[390]",
        get_data_mem(dut, 0x390),
        36
    )


# ============================================================
# TEST 28
# SINGLE DIRTY LINE WRITE-BACK
# ============================================================

async def test_single_dirty_writeback(dut, reg):

    test_header(
        28,
        "SINGLE DIRTY LINE WRITE-BACK"
    )

    A = 0x100
    B = 0x120

    program = [

        load(1, A),

        load_imm(2, 0x123),
        store(2, A),

        load(3, B),

        halt(),
    ]

    memory = {

        A:     0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x11111111,
        B + 1: 0x22222222,
        B + 2: 0x33333333,
        B + 3: 0x44444444,
    }

    await prepare_test(
        dut,
        program,
        memory
    )

    assert await wait_for_halt(
        dut,
        max_cycles=10000,
        test_name="TEST 28"
    )

    for _ in range(30):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "CPU A write",
        get_reg(dut, 2),
        0x00000123
    )

    reg.check(
        "Backing A after WB",
        get_data_mem(dut, A),
        0x00000123
    )

    reg.check(
        "Backing A+1 preserved",
        get_data_mem(dut, A + 1),
        0xBBBBBBBB
    )

    reg.check(
        "Backing A+2 preserved",
        get_data_mem(dut, A + 2),
        0xCCCCCCCC
    )

    reg.check(
        "Backing A+3 preserved",
        get_data_mem(dut, A + 3),
        0xDDDDDDDD
    )

    reg.check(
        "Conflict B loaded",
        get_reg(dut, 3),
        0x11111111
    )


# ============================================================
# TEST 29
# FULL DIRTY CACHE LINE WRITE-BACK
# ============================================================

async def test_full_dirty_line_writeback(dut, reg):

    test_header(
        29,
        "FULL DIRTY CACHE LINE WRITE-BACK"
    )

    A = 0x140
    B = 0x160

    program = [

        load(1, A + 0),
        load(2, A + 1),
        load(3, A + 2),
        load(4, A + 3),

        load_imm(5, 0x111),
        store(5, A + 0),

        load_imm(5, 0x222),
        store(5, A + 1),

        load_imm(5, 0x333),
        store(5, A + 2),

        load_imm(5, 0x444),
        store(5, A + 3),

        load(6, B),

        halt(),
    ]

    memory = {

        A + 0: 0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x55555555,
        B + 1: 0x66666666,
        B + 2: 0x77777777,
        B + 3: 0x88888888,
    }

    await prepare_test(
        dut,
        program,
        memory
    )

    assert await wait_for_halt(
        dut,
        max_cycles=15000,
        test_name="TEST 29"
    )

    for _ in range(40):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "WB WORD 0",
        get_data_mem(dut, A + 0),
        0x00000111
    )

    reg.check(
        "WB WORD 1",
        get_data_mem(dut, A + 1),
        0x00000222
    )

    reg.check(
        "WB WORD 2",
        get_data_mem(dut, A + 2),
        0x00000333
    )

    reg.check(
        "WB WORD 3",
        get_data_mem(dut, A + 3),
        0x00000444
    )

    reg.check(
        "VICTIM LOAD",
        get_reg(dut, 6),
        0x55555555
    )


# ============================================================
# TEST 30
# RELOAD AFTER DIRTY WRITE-BACK
# ============================================================

async def test_reload_after_writeback(dut, reg):

    test_header(30, "RELOAD AFTER DIRTY WRITE-BACK")

    A = 0x180
    B = 0x1A0

    program = []

    program += [
        load(1, A),
    ]

    program += make_u32(2, 0x0000DEAD)

    program += [
        store(2, A),

        load(3, B),

        load(4, A),

        halt(),
    ]

    memory = {
        A:     0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x12345678,
        B + 1: 0x11111111,
        B + 2: 0x22222222,
        B + 3: 0x33333333,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        max_cycles=15000,
        test_name="TEST 30"
    )

    for _ in range(40):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "CPU dirty value",
        get_reg(dut, 2),
        0x0000DEAD
    )

    reg.check(
        "Reloaded dirty A",
        get_reg(dut, 4),
        0x0000DEAD
    )

    reg.check(
        "Backing A",
        get_data_mem(dut, A),
        0x0000DEAD
    )


# ============================================================
# TEST 31
# TWO DIRTY CACHE LINES
# ============================================================

async def test_two_dirty_lines(dut, reg):

    test_header(31, "TWO DIRTY CACHE LINES")

    A = 0x200
    C = 0x220
    E = 0x240

    program = []

    program += [
        load(1, A),
    ]

    program += make_u32(2, 0x0000AAAA)

    program += [
        store(2, A),
        load(3, C),
    ]

    program += make_u32(4, 0x0000CCCC)

    program += [
        store(4, C),

        load(5, E),

        halt(),
    ]

    memory = {
        A:     0xAAAAAAAA,
        A + 1: 0xAAAAAAAA,
        A + 2: 0xAAAAAAAA,
        A + 3: 0xAAAAAAAA,

        C:     0xCCCCCCCC,
        C + 1: 0xCCCCCCCC,
        C + 2: 0xCCCCCCCC,
        C + 3: 0xCCCCCCCC,

        E:     0xEEEEEEEE,
        E + 1: 0xEEEEEEEE,
        E + 2: 0xEEEEEEEE,
        E + 3: 0xEEEEEEEE,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        max_cycles=20000,
        test_name="TEST 31"
    )

    for _ in range(60):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "A write-back",
        get_data_mem(dut, A),
        0x0000AAAA
    )

    reg.check(
        "C write-back",
        get_data_mem(dut, C),
        0x0000CCCC
    )

    reg.check(
        "E memory",
        get_data_mem(dut, E),
        0xEEEEEEEE
    )


# ============================================================
# TEST 32
# CLEAN EVICTION
# ============================================================

async def test_clean_eviction_no_writeback(dut, reg):

    test_header(
        32,
        "CLEAN EVICTION"
    )

    A = 0x280
    B = 0x2A0

    program = [

        load(1, A),

        load(2, B),

        halt(),
    ]

    memory = {

        A:     0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x12345678,
    }

    await prepare_test(
        dut,
        program,
        memory
    )

    assert await wait_for_halt(
        dut,
        max_cycles=10000,
        test_name="TEST 32"
    )

    for _ in range(40):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "Clean A word 0",
        get_data_mem(dut, A),
        0xAAAAAAAA
    )

    reg.check(
        "Clean A word 1",
        get_data_mem(dut, A + 1),
        0xBBBBBBBB
    )

    reg.check(
        "Clean A word 2",
        get_data_mem(dut, A + 2),
        0xCCCCCCCC
    )

    reg.check(
        "Clean A word 3",
        get_data_mem(dut, A + 3),
        0xDDDDDDDD
    )


# ============================================================
# TEST 33
# WRITE-BACK FOLLOWED BY NEW REQUEST
# ============================================================

async def test_writeback_stall_and_resume(dut, reg):

    test_header(33, "WRITE-BACK STALL AND RESUME")

    A = 0x2C0
    B = 0x2E0

    program = [
        load(1, A),
    ]

    program += make_u32(2, 0x0000CAFE)

    program += [
        store(2, A),

        load(3, B),

        load(4, B + 1),

        halt(),
    ]

    memory = {
        A:     0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x11111111,
        B + 1: 0x22222222,
        B + 2: 0x33333333,
        B + 3: 0x44444444,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        max_cycles=20000,
        test_name="TEST 33"
    )

    for _ in range(50):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "CPU dirty value",
        get_reg(dut, 2),
        0x0000CAFE
    )

    reg.check(
        "Victim write-back",
        get_data_mem(dut, A),
        0x0000CAFE
    )

    reg.check(
        "New line word 0",
        get_reg(dut, 3),
        0x11111111
    )

    reg.check(
        "New line word 1",
        get_reg(dut, 4),
        0x22222222
    )


# ============================================================
# TEST 34
# REPEATED DIRTY EVICTION
# ============================================================

async def test_repeated_dirty_eviction(dut, reg):

    test_header(34, "REPEATED DIRTY EVICTION")

    A = 0x300
    B = 0x320

    program = []

    # ========================================================
    # FIRST A
    # ========================================================

    program += [
        load(1, A),
    ]

    program += make_u32(2, 0x00001001)

    program += [
        store(2, A),

        load(3, B),

        # ====================================================
        # A AGAIN
        # ====================================================

        load(4, A),
    ]

    program += make_u32(5, 0x00001002)

    program += [
        store(5, A),

        load(6, B),

        load(7, A),

        halt(),
    ]

    memory = {
        A:     0xAAAAAAAA,
        A + 1: 0xBBBBBBBB,
        A + 2: 0xCCCCCCCC,
        A + 3: 0xDDDDDDDD,

        B:     0x11111111,
        B + 1: 0x22222222,
        B + 2: 0x33333333,
        B + 3: 0x44444444,
    }

    await prepare_test(dut, program, memory)

    assert await wait_for_halt(
        dut,
        max_cycles=30000,
        test_name="TEST 34"
    )

    for _ in range(80):
        await RisingEdge(dut.slow_clk)

    reg.check(
        "Final A write-back",
        get_data_mem(dut, A),
        0x00001002
    )

    reg.check(
        "Final reload",
        get_reg(dut, 7),
        0x00001002
    )

    reg.check(
        "B preserved",
        get_data_mem(dut, B),
        0x11111111
    )


# ============================================================
# MASTER REGRESSION
# ============================================================

@cocotb.test()
async def test_cpu_regression(dut):

    # --------------------------------------------------------
    # START CLOCKS
    # --------------------------------------------------------

    await start_clocks(dut)

    reg = Regression()

    # --------------------------------------------------------
    # INITIAL RESET
    # --------------------------------------------------------

    await assert_reset(dut)

    # --------------------------------------------------------
    # BASIC / ISA TESTS
    # --------------------------------------------------------

    await test_basic_memory(dut, reg)

    await test_alu(dut, reg)

    await test_immediates(dut, reg)

    await test_shifts(dut, reg)

    await test_compare(dut, reg)

    await test_beq(dut, reg)

    await test_bne(dut, reg)

    await test_signed_unsigned_branches(dut, reg)

    await test_jumps(dut, reg)

    await test_indirect_memory(dut, reg)

    # --------------------------------------------------------
    # CACHE TESTS
    # --------------------------------------------------------

    await test_cache_line(dut, reg)

    await test_cache_conflict(dut, reg)

    # --------------------------------------------------------
    # RESET
    # --------------------------------------------------------

    await test_reset(dut, reg)

    # --------------------------------------------------------
    # CORNER CASES
    # --------------------------------------------------------

    await test_boundaries(dut, reg)

    await test_long_program(dut, reg)

    await test_arithmetic_corner_cases(dut, reg)

    await test_immediate_boundaries(dut, reg)

    await test_shift_rotate_boundaries(dut, reg)

    await test_signed_unsigned_compare(dut, reg)

    await test_all_branches(dut, reg)

    await test_jmp_reg(dut, reg)

    # --------------------------------------------------------
    # CALL / RET
    # --------------------------------------------------------

    await test_call_ret(dut, reg)

    await test_nested_call_ret(dut, reg)

    # --------------------------------------------------------
    # MEMORY / CDC
    # --------------------------------------------------------

    await test_direct_memory_boundaries(dut, reg)

    await test_indirect_address_boundaries(dut, reg)

    await test_memory_stress(dut, reg)

    await test_mixed_stress(dut, reg)

    # --------------------------------------------------------
    # WRITE-BACK / DIRTY CACHE TESTS
    # --------------------------------------------------------

    await test_single_dirty_writeback(dut, reg)

    await test_full_dirty_line_writeback(dut, reg)

    await test_reload_after_writeback(dut, reg)

    await test_two_dirty_lines(dut, reg)

    await test_clean_eviction_no_writeback(dut, reg)

    await test_writeback_stall_and_resume(dut, reg)

    await test_repeated_dirty_eviction(dut, reg)

    # --------------------------------------------------------
    # FINAL SUMMARY
    # --------------------------------------------------------

    print()
    print("================================================")
    print("             CPU REGRESSION SUMMARY")
    print("================================================")

    print(f"TOTAL CHECKS : {reg.total}")
    print(f"PASSED       : {reg.passed}")
    print(f"FAILED       : {reg.failed}")

    print("================================================")

    if reg.failed == 0:

        print("          CPU REGRESSION PASSED")

    else:

        print("          CPU REGRESSION FAILED")

    print("================================================")

    assert reg.failed == 0, (
        f"Regression failed: "
        f"{reg.failed}/{reg.total} checks failed"
    )
