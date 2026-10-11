import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

# Deterministic full-system Cocotb regression for the pipelined CPU.
# Covers only:
#   1. Pipeline hazards / dependencies
#   2. Cache hits, misses, dirty eviction, write-back and reload
#   3. Branches, jumps and pipeline flushing
#
# ISA encoding: opcode[31:24], rd[23:20], rs1[19:16],
#               rs2[15:12], immediate/address[11:0].

OP_NOP       = 0x00
OP_LOAD      = 0x01
OP_LOAD_IND  = 0x02
OP_LOAD_IMM  = 0x03
OP_STORE     = 0x04
OP_STORE_IND = 0x05
OP_ADD       = 0x06
OP_SUB       = 0x07
OP_CMP       = 0x0C
OP_JMP       = 0x0E
OP_JMP_IF    = 0x0F
OP_XOR       = 0x10
OP_ADDI      = 0x16
OP_LUI       = 0x1E
OP_BEQ       = 0x20
OP_BNE       = 0x21
OP_BLT       = 0x22
OP_BGE       = 0x23
OP_BLTU      = 0x24
OP_BGEU      = 0x25
OP_JMP_REG   = 0x26

MASK32 = 0xFFFFFFFF
PROGRAM_WORDS_TO_CLEAR = 128
DATA_WORDS_TO_CLEAR = 1024

def r_type(op, rd=0, rs1=0, rs2=0):
    return (((op & 0xFF) << 24) |
            ((rd & 0xF) << 20) |
            ((rs1 & 0xF) << 16) |
            ((rs2 & 0xF) << 12))

def i_type(op, rd=0, rs1=0, imm=0):
    return (((op & 0xFF) << 24) |
            ((rd & 0xF) << 20) |
            ((rs1 & 0xF) << 16) |
            (imm & 0xFFF))

def load_imm(rd, imm):
    return i_type(OP_LOAD_IMM, rd, 0, imm)

def load(rd, address):
    return i_type(OP_LOAD, rd, 0, address)

def store(rd, address):
    return i_type(OP_STORE, rd, 0, address)

def load_ind(rd, rs1):
    return r_type(OP_LOAD_IND, rd, rs1, 0)

def store_ind(data_rd, address_rs):
    # STORE_IND reads data from R[rd] and address from R[rs2].
    return r_type(OP_STORE_IND, data_rd, 0, address_rs)

def jmp(address):
    return i_type(OP_JMP, 0, 0, address)

def jmp_if(rs1, address):
    return i_type(OP_JMP_IF, 0, rs1, address)

def branch(op, address):
    return i_type(op, 0, 0, address)

def jmp_reg(rs1):
    return i_type(OP_JMP_REG, 0, rs1, 0)

def add(rd, rs1, rs2):
    return r_type(OP_ADD, rd, rs1, rs2)

def sub(rd, rs1, rs2):
    return r_type(OP_SUB, rd, rs1, rs2)

def xor(rd, rs1, rs2):
    return r_type(OP_XOR, rd, rs1, rs2)

def cmp(rs1, rs2):
    return r_type(OP_CMP, 0, rs1, rs2)

def lui(rd, imm):
    return i_type(OP_LUI, rd, 0, imm)

def loop_program(instructions, loop_addr=None):
    """Append a self-jump so execution cannot fall into stale program words."""
    program = list(instructions)
    if loop_addr is None:
        loop_addr = len(program)
    program.append(jmp(loop_addr))
    return program

def sig_value(handle):
    value = handle.value
    if not value.is_resolvable:
        raise AssertionError(f"{handle._name} contains X/Z: {value}")
    return value.to_unsigned()

def get_reg(dut, index):
    return sig_value(dut.u_cpu_core.R[index])

def get_mem(dut, address):
    return sig_value(dut.u_data_memory.mem[address])

class Checks:
    def __init__(self, dut):
        self.dut = dut
        self.total = 0
        self.failed = []

    def eq(self, label, actual, expected):
        self.total += 1
        if actual != expected:
            msg = f"{label}: actual=0x{actual:08x}, expected=0x{expected:08x}"
            self.failed.append(msg)
            self.dut._log.error("FAIL %s", msg)
        else:
            self.dut._log.info("PASS %-43s 0x%08x", label, actual)

    def reg(self, label, index, expected):
        self.eq(f"{label} (R{index})", get_reg(self.dut, index), expected & MASK32)

    def mem(self, label, address, expected):
        self.eq(f"{label} (MEM[{address:#05x}])",
                get_mem(self.dut, address), expected & MASK32)

    def summary(self):
        self.dut._log.info("=" * 64)
        self.dut._log.info("COCOTB CPU STRESS SUMMARY: %d checks, %d passed, %d failed",
                           self.total, self.total - len(self.failed), len(self.failed))
        for item in self.failed:
            self.dut._log.error("FAILED: %s", item)
        self.dut._log.info("=" * 64)

async def edge_wait(clk, cycles=1):
    for _ in range(cycles):
        await RisingEdge(clk)
        # Move beyond the edge/NBA update region before reading or writing signals.
        await Timer(1, unit="ns")

async def reset_and_load(dut, program, memory_init=None):
    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0
    await edge_wait(dut.fast_clk, 8)
    await edge_wait(dut.slow_clk, 4)

    pmem = dut.u_program_memory.mem
    dmem = dut.u_data_memory.mem

    # Keep the program region deterministic on every scenario.
    for i in range(PROGRAM_WORDS_TO_CLEAR):
        pmem[i].value = 0
    for i in range(DATA_WORDS_TO_CLEAR):
        dmem[i].value = 0

    for address, instruction in enumerate(program):
        if address >= PROGRAM_WORDS_TO_CLEAR:
            raise ValueError(f"Test program too large: {len(program)} instructions")
        pmem[address].value = instruction & MASK32

    if memory_init:
        for address, value in memory_init.items():
            dmem[address].value = value & MASK32

    # Allow the reset state to settle before releasing both domains.
    await edge_wait(dut.fast_clk, 2)
    dut.fast_rst_n.value = 1
    dut.slow_rst_n.value = 1
    await edge_wait(dut.fast_clk, 5)

async def run_case(dut, program, checks, memory_init=None, cycles=500, name="scenario"):
    dut._log.info("")
    dut._log.info("----- %s -----", name)
    await reset_and_load(dut, program, memory_init)
    await edge_wait(dut.fast_clk, cycles)

def branch_program(op, init_r1, init_r2):
    # PC 3: branch to PC 7 when taken.
    # On the not-taken path, R4 is dirtied and R3 gets 0x111.
    # On the taken path, R4 must remain zero, R3 gets 0x222, and
    # the immediately following target instruction sets R5=0x456.
    return loop_program([
        init_r1,                         # 0
        init_r2,                         # 1
        cmp(1, 2),                       # 2
        branch(op, 7),                   # 3
        load_imm(4, 0xBAD),              # 4 wrong path if taken
        load_imm(3, 0x111),              # 5 not-taken marker
        jmp(10),                         # 6 skip taken target on not-taken path
        load_imm(3, 0x222),              # 7 taken marker / branch target
        load_imm(5, 0x456),              # 8 first instruction after target
        jmp(10),                         # 9 skip to loop
    ], loop_addr=10)

@cocotb.test()
async def test_cpu_pipeline_stress(dut):
    cocotb.start_soon(Clock(dut.fast_clk, 6.666, unit="ns").start())
    cocotb.start_soon(Clock(dut.slow_clk, 14.286, unit="ns").start())

    checks = Checks(dut)

    # Clear all program/data locations once, including unused words, while
    # reset is asserted. Each scenario then clears the active address range.
    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0
    await edge_wait(dut.fast_clk, 8)
    await edge_wait(dut.slow_clk, 4)
    for i in range(4096):
        dut.u_program_memory.mem[i].value = 0
    for i in range(16384):
        dut.u_data_memory.mem[i].value = 0
    await edge_wait(dut.fast_clk, 2)

    # ================================================================
    # 1. PIPELINE HAZARDS / DEPENDENCIES
    # ================================================================

    # Two consecutive loads feed both operands of ADD; then a dependency
    # chain consumes the ADD result in the next instructions.
    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        add(3, 1, 2),
        i_type(OP_ADDI, 4, 3, 5),
        add(5, 4, 1),
        xor(6, 5, 3),
    ])
    await run_case(dut, prog, checks,
                   {0x100: 0x123, 0x101: 0x456},
                   cycles=1800, name="HAZARD: two load operands + dependency chain")
    checks.reg("load source A", 1, 0x123)
    checks.reg("load source B", 2, 0x456)
    checks.reg("ADD using both loaded operands", 3, 0x579)
    checks.reg("ADDI dependent on ADD", 4, 0x57E)
    checks.reg("ADD dependent on prior ADDI", 5, 0x6A1)
    checks.reg("XOR dependent on prior results", 6, 0x6A1 ^ 0x579)

    # Load-use dependency on a single source and a store immediately consuming
    # the loaded register as its write-data operand.
    prog = loop_program([
        load(1, 0x110),
        i_type(OP_ADDI, 2, 1, 7),
        store(1, 0x210),
        load(3, 0x210),
        add(4, 2, 3),
    ])
    await run_case(dut, prog, checks,
                   {0x110: 0x222},
                   cycles=1800, name="HAZARD: load-use + forwarded store data")
    checks.reg("load source", 1, 0x222)
    checks.reg("ADDI immediately after load", 2, 0x229)
    checks.reg("load after dependent store", 3, 0x222)
    checks.reg("ADD using dependent values", 4, 0x44B)
    checks.mem("stored forwarded load value", 0x210, 0x222)

    # Consecutive loads and stores, then reload each stored word.
    prog = loop_program([
        load(1, 0x120),
        load(2, 0x121),
        load(3, 0x122),
        store(1, 0x220),
        store(2, 0x221),
        store(3, 0x222),
        load(4, 0x220),
        load(5, 0x221),
        load(6, 0x222),
    ])
    await run_case(dut, prog, checks,
                   {0x120: 0xA1A1, 0x121: 0xB2B2, 0x122: 0xC3C3},
                   cycles=2200, name="HAZARD: consecutive loads/stores")
    checks.reg("consecutive load 0", 1, 0xA1A1)
    checks.reg("consecutive load 1", 2, 0xB2B2)
    checks.reg("consecutive load 2", 3, 0xC3C3)
    checks.reg("reload stored word 0", 4, 0xA1A1)
    checks.reg("reload stored word 1", 5, 0xB2B2)
    checks.reg("reload stored word 2", 6, 0xC3C3)
    checks.mem("stored word 0", 0x220, 0xA1A1)
    checks.mem("stored word 1", 0x221, 0xB2B2)
    checks.mem("stored word 2", 0x222, 0xC3C3)

    # ================================================================
    # 2. CACHE HITS, MISSES, CONFLICTS, DIRTY EVICTION / WRITE-BACK
    # ================================================================

    # First access misses and refills a four-word line. Repeated accesses
    # should hit; writes to words within that line should be visible on reload.
    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        load(3, 0x102),
        load(4, 0x103),
        load(5, 0x100),        # repeated hit
        load(6, 0x103),        # repeated hit at final offset
        load_imm(7, 0x777),
        store(7, 0x101),       # dirty write hit
        load(8, 0x101),
        load(9, 0x100),
        load(10, 0x102),
    ])
    init = {0x100: 0x11111111, 0x101: 0x22222222,
            0x102: 0x33333333, 0x103: 0x44444444}
    await run_case(dut, prog, checks, init, cycles=2200,
                   name="CACHE: refill, repeated hits, word offsets, dirty hit")
    checks.reg("line offset 0", 1, 0x11111111)
    checks.reg("line offset 1", 2, 0x22222222)
    checks.reg("line offset 2", 3, 0x33333333)
    checks.reg("line offset 3", 4, 0x44444444)
    checks.reg("repeated hit offset 0", 5, 0x11111111)
    checks.reg("repeated hit offset 3", 6, 0x44444444)
    checks.reg("read back dirty word", 8, 0x777)
    checks.reg("read back unchanged word 0", 9, 0x11111111)
    checks.reg("read back unchanged word 2", 10, 0x33333333)

    # Addresses 0x100 and 0x120 map to the same cache index for an 8-line,
    # four-word/line cache. Dirty A, access B to force eviction/write-back,
    # then reload A and verify all words and preserved neighbors.
    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        load_imm(3, 0x555),
        store(3, 0x100),
        load_imm(4, 0x666),
        store(4, 0x102),
        load(5, 0x120),        # conflicting line forces dirty eviction
        load(6, 0x100),        # evicts B and refills A
        load(7, 0x101),
        load(8, 0x102),
        load(9, 0x103),
    ])
    init = {0x100: 0xAAAA0000, 0x101: 0xBBBB0001,
            0x102: 0xCCCC0002, 0x103: 0xDDDD0003,
            0x120: 0x12345678, 0x121: 0x21212121,
            0x122: 0x32323232, 0x123: 0x43434343}
    await run_case(dut, prog, checks, init, cycles=3000,
                   name="CACHE: same-index conflict, dirty eviction, full write-back")
    checks.reg("conflicting line value", 5, 0x12345678)
    checks.reg("reloaded dirty word 0", 6, 0x555)
    checks.reg("preserved word 1", 7, 0xBBBB0001)
    checks.reg("reloaded dirty word 2", 8, 0x666)
    checks.reg("preserved word 3", 9, 0xDDDD0003)
    checks.mem("write-back dirty word 0", 0x100, 0x555)
    checks.mem("write-back preserves word 1", 0x101, 0xBBBB0001)
    checks.mem("write-back dirty word 2", 0x102, 0x666)
    checks.mem("write-back preserves word 3", 0x103, 0xDDDD0003)

    # Alternate between two conflicting lines several times. This checks
    # refill after eviction and repeatability of clean conflict misses.
    prog = loop_program([
        load(1, 0x140),
        load(2, 0x160),
        load(3, 0x140),
        load(4, 0x160),
        load(5, 0x141),
        load(6, 0x161),
    ])
    await run_case(dut, prog, checks,
                   {0x140: 0x14001400, 0x141: 0x14101410,
                    0x160: 0x16001600, 0x161: 0x16101610},
                   cycles=2600, name="CACHE: repeated clean conflict misses")
    checks.reg("conflict A first", 1, 0x14001400)
    checks.reg("conflict B first", 2, 0x16001600)
    checks.reg("conflict A reload", 3, 0x14001400)
    checks.reg("conflict B reload", 4, 0x16001600)
    checks.reg("conflict A neighbor", 5, 0x14101410)
    checks.reg("conflict B neighbor", 6, 0x16101610)

    # ================================================================
    # 3. CONTROL FLOW / FLUSHING
    # ================================================================

    # Unconditional jump: wrong-path instructions must not commit. Check the
    # target instruction and the instruction immediately following it.
    prog = loop_program([
        jmp(4),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
    ])
    await run_case(dut, prog, checks, cycles=350, name="CONTROL: JMP + flush + target successor")
    checks.reg("JMP wrong path flushed", 4, 0)
    checks.reg("JMP target instruction", 3, 0x321)
    checks.reg("JMP target successor", 5, 0x456)

    # JMP_IF taken and not taken.
    prog = loop_program([
        load_imm(1, 1),
        jmp_if(1, 4),
        load_imm(4, 0xBAD),
        jmp(7),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
        jmp(7),
    ], loop_addr=7)
    await run_case(dut, prog, checks, cycles=350, name="CONTROL: JMP_IF taken")
    checks.reg("JMP_IF taken wrong path", 4, 0)
    checks.reg("JMP_IF taken target", 3, 0x321)
    checks.reg("JMP_IF target successor", 5, 0x456)

    prog = loop_program([
        load_imm(1, 0),
        jmp_if(1, 4),
        load_imm(4, 0xBAD),
        jmp(7),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
        jmp(7),
    ], loop_addr=7)
    await run_case(dut, prog, checks, cycles=350, name="CONTROL: JMP_IF not taken")
    checks.reg("JMP_IF not-taken fall-through", 4, 0xBAD)
    checks.reg("JMP_IF target not executed", 3, 0)
    checks.reg("JMP_IF skipped target successor", 5, 0)

    # Register-indirect jump.
    prog = loop_program([
        load_imm(1, 5),
        jmp_reg(1),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
    ])
    await run_case(dut, prog, checks, cycles=350, name="CONTROL: JMP_REG + flush")
    checks.reg("JMP_REG wrong path flushed", 4, 0)
    checks.reg("JMP_REG target", 3, 0x321)
    checks.reg("JMP_REG target successor", 5, 0x456)

    # For every conditional branch, test both taken and not-taken paths.
    # A taken branch must flush the fall-through writes; an untaken branch
    # must execute the fall-through marker and skip the target block.
    branch_cases = [
        ("BEQ taken",       OP_BEQ,  load_imm(1, 5),  load_imm(2, 5),  True),
        ("BEQ not taken",   OP_BEQ,  load_imm(1, 5),  load_imm(2, 6),  False),
        ("BNE taken",       OP_BNE,  load_imm(1, 5),  load_imm(2, 6),  True),
        ("BNE not taken",   OP_BNE,  load_imm(1, 5),  load_imm(2, 5),  False),
        ("BLT taken",       OP_BLT,  load_imm(1, 1),  load_imm(2, 2),  True),
        ("BLT not taken",   OP_BLT,  load_imm(1, 2),  load_imm(2, 1),  False),
        ("BGE taken",       OP_BGE,  load_imm(1, 2),  load_imm(2, 1),  True),
        ("BGE not taken",   OP_BGE,  load_imm(1, 1),  load_imm(2, 2),  False),
        ("BLTU taken",      OP_BLTU, load_imm(1, 1),  load_imm(2, 2),  True),
        ("BLTU not taken",  OP_BLTU, load_imm(1, 2),  load_imm(2, 1),  False),
        ("BGEU taken",      OP_BGEU, load_imm(1, 2),  load_imm(2, 1),  True),
        ("BGEU not taken",  OP_BGEU, load_imm(1, 1),  load_imm(2, 2),  False),
        # Signed-vs-unsigned distinction: 0xFFF00000 is negative signed,
        # but a large positive unsigned value.
        ("BLT signed negative", OP_BLT,  lui(1, 0xFFF), load_imm(2, 1), True),
        ("BLTU unsigned large", OP_BLTU, lui(1, 0xFFF), load_imm(2, 1), False),
        ("BGE signed negative", OP_BGE,  lui(1, 0xFFF), load_imm(2, 1), False),
        ("BGEU unsigned large", OP_BGEU, lui(1, 0xFFF), load_imm(2, 1), True),
    ]

    for name, op, init1, init2, taken in branch_cases:
        prog = branch_program(op, init1, init2)
        await run_case(dut, prog, checks, cycles=450, name=f"CONTROL: {name}")
        if taken:
            checks.reg(f"{name}: wrong-path write flushed", 4, 0)
            checks.reg(f"{name}: taken target marker", 3, 0x222)
            checks.reg(f"{name}: target successor executed", 5, 0x456)
        else:
            checks.reg(f"{name}: fall-through write", 4, 0xBAD)
            checks.reg(f"{name}: not-taken marker", 3, 0x111)
            checks.reg(f"{name}: target successor skipped", 5, 0)

    checks.summary()
    assert not checks.failed, (
        f"CPU pipeline stress regression failed: {len(checks.failed)} of "
        f"{checks.total} checks failed. See log above."
    )

