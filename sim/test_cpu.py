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
OP_CALL      = 0x27
OP_RET       = 0x28

MASK32 = 0xFFFFFFFF
PROGRAM_WORDS_TO_CLEAR = 1024
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

def call(address):
    return i_type(OP_CALL, 0, 0, address)

def ret():
    return i_type(OP_RET, 0, 0, 0)

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

    # ================================================================
    # 4. CALL / RET
    # ================================================================

    # Simple call/return: CALL at PC 0 saves PC+1 (=1) to R15 and the stack,
    # jumps to PC 4, then RET redirects through R15. The RET stack read should
    # restore the saved link value into R15 and restore the stack pointer.
    prog = [
        call(4),                    # 0: call subroutine
        load_imm(2, 0x111),         # 1: return address; must execute
        jmp(7),                     # 2: skip subroutine after return
        load_imm(7, 0xBAD),         # 3: should never execute
        load_imm(3, 0x222),         # 4: subroutine marker
        ret(),                      # 5: return via R15
        load_imm(7, 0xBAD),         # 6: should not execute
        jmp(7),                     # 7: stop in a loop
    ]
    await run_case(dut, prog, checks, cycles=900,
                   name="CALL/RET: simple call, stack save and link restore")
    checks.reg("CALL saved return path executed", 2, 0x111)
    checks.reg("CALL subroutine executed", 3, 0x222)
    checks.reg("CALL wrong path before target flushed", 7, 0)
    checks.reg("R15 after simple RET", 15, 1)
    checks.eq("stack pointer restored after simple RET",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.mem("CALL saved return address", 0x3FFF, 1)

    # Nested call/return: outer CALL pushes return address 1; inner CALL pushes
    # return address 6. After the inner RET, the outer RET must return to PC 1.
    # This is deliberately included as a stronger test: it will expose whether
    # RET restores the PREVIOUS link from the stack, rather than reloading the
    # same return address that the current RET just used.
    prog = [
        call(4),                    # 0: main -> function A; saves 1
        load_imm(2, 0x111),         # 1: outer return marker
        jmp(12),                    # 2: finish
        load_imm(7, 0xBAD),         # 3: should not execute
        load_imm(4, 0x444),         # 4: function A marker
        call(8),                    # 5: function A -> function B; saves 6
        load_imm(5, 0x555),         # 6: resume function A after B returns
        ret(),                      # 7: function A -> main (should use saved 1)
        load_imm(6, 0x666),         # 8: function B marker
        ret(),                      # 9: function B -> function A (uses link 6)
        load_imm(7, 0xBAD),         # 10: should not execute
        load_imm(7, 0xBAD),         # 11: should not execute
        jmp(12),                    # 12: finish loop
    ]
    await run_case(dut, prog, checks, cycles=1400,
                   name="CALL/RET: nested calls restore previous link")
    checks.reg("outer function executed", 4, 0x444)
    checks.reg("inner function executed", 6, 0x666)
    checks.reg("inner return resumed outer function", 5, 0x555)
    checks.reg("outer return resumed main", 2, 0x111)
    checks.reg("nested CALL wrong path flushed", 7, 0)
    checks.eq("stack pointer restored after nested RETs",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.mem("outer return address remains on stack", 0x3FFF, 1)
    checks.mem("inner return address remains on stack", 0x3FFE, 6)

    # Two separate calls from main to different subroutines. This checks that
    # RET returns to the correct call site each time and that the stack is
    # reusable after a completed call.
    prog = [
        call(5),                    # 0: first call saves 1
        load_imm(2, 0x111),         # 1: first return marker
        call(8),                    # 2: second call saves 3
        load_imm(3, 0x333),         # 3: second return marker
        jmp(11),                    # 4: finish
        load_imm(4, 0x444),         # 5: first subroutine
        ret(),                      # 6: return to 1
        load_imm(7, 0xBAD),         # 7: must not execute
        load_imm(5, 0x555),         # 8: second subroutine
        ret(),                      # 9: return to 3
        load_imm(7, 0xBAD),         # 10: must not execute
        jmp(11),                    # 11: finish loop
    ]
    await run_case(dut, prog, checks, cycles=1200,
                   name="CALL/RET: two sequential calls from main")
    checks.reg("first subroutine ran", 4, 0x444)
    checks.reg("first call returned to instruction 1", 2, 0x111)
    checks.reg("second subroutine ran", 5, 0x555)
    checks.reg("second call returned to instruction 3", 3, 0x333)
    checks.reg("sequential calls flushed wrong path", 7, 0)
    checks.eq("stack pointer restored after sequential calls",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.reg("R15 restored to second call return address", 15, 3)
    # Raw backing RAM may be stale when the stack write is resident in cache.

    # CALL target begins with RET. This checks the smallest legal subroutine
    # and ensures the return path works without an intervening register write.
    prog = [
        call(3),                    # 0: save return address 1
        load_imm(2, 0x222),         # 1: must execute after RET
        jmp(5),                     # 2: finish
        ret(),                      # 3: immediate return
        load_imm(7, 0xBAD),         # 4: must not execute
        jmp(5),                     # 5: finish loop
    ]
    await run_case(dut, prog, checks, cycles=900,
                   name="CALL/RET: immediate return at subroutine entry")
    checks.reg("immediate RET returned to caller", 2, 0x222)
    checks.reg("immediate RET flushed fall-through", 7, 0)
    checks.reg("immediate RET restored link register", 15, 1)
    checks.eq("stack pointer restored after immediate RET",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)


    # ================================================================
    # 5. ADDITIONAL CALL / RET CORNER CASES
    # ================================================================

    # Same subroutine called from two distinct call sites. The subroutine
    # must return to each caller's own PC+1, not reuse a stale link value.
    prog = [
        call(8),                    # 0: return to 1
        load_imm(2, 0x111),         # 1: first caller marker
        call(8),                    # 2: return to 3
        load_imm(3, 0x333),         # 3: second caller marker
        jmp(6),                     # 4
        load_imm(7, 0xBAD),         # 5: wrong path
        jmp(6),                     # 6: finish loop
        load_imm(7, 0xBAD),         # 7: must not execute
        load_imm(4, 0x444),         # 8: shared subroutine
        ret(),                      # 9
    ]
    await run_case(dut, prog, checks, cycles=1500,
                   name="CALL/RET: same target from different callers")
    checks.reg("shared subroutine executed", 4, 0x444)
    checks.reg("first call returned to PC+1", 2, 0x111)
    checks.reg("second call returned to PC+1", 3, 0x333)
    checks.reg("shared target wrong path flushed", 7, 0)
    checks.eq("SP restored after shared-target calls",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)

    # Branch taken directly to CALL. Instructions on the branch fall-through
    # must not commit, and the CALL must still save its own PC+1.
    prog = [
        load_imm(1, 0x55),           # 0
        load_imm(2, 0x55),           # 1
        cmp(1, 2),                   # 2
        branch(OP_BEQ, 5),           # 3: taken to CALL
        load_imm(7, 0xBAD),          # 4: branch wrong path
        call(9),                     # 5: return to 6
        load_imm(5, 0x555),          # 6: call return marker
        jmp(8),                      # 7
        jmp(8),                      # 8: finish loop
        load_imm(6, 0x666),          # 9: subroutine marker
        ret(),                       # 10
    ]
    await run_case(dut, prog, checks, cycles=1400,
                   name="CALL/RET: taken branch immediately to CALL")
    checks.reg("branch fall-through flushed", 7, 0)
    checks.reg("branch-to-CALL subroutine ran", 6, 0x666)
    checks.reg("branch-to-CALL returned correctly", 5, 0x555)
    checks.eq("SP restored after branch-to-CALL",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)

    # A RET is followed in memory by a CALL that should execute only after
    # returning to the caller's continuation. This stresses RET redirection
    # followed by another control transfer.
    prog = [
        call(6),                    # 0 -> subroutine A, return to 1
        call(9),                    # 1 -> subroutine B, return to 2
        load_imm(2, 0x222),         # 2: continuation after second RET
        jmp(5),                     # 3
        load_imm(7, 0xBAD),         # 4 wrong path
        jmp(5),                     # 5 finish loop
        load_imm(4, 0x444),         # 6 subroutine A
        ret(),                      # 7
        load_imm(7, 0xBAD),         # 8 must not execute
        load_imm(5, 0x555),         # 9 subroutine B
        ret(),                      # 10
    ]
    await run_case(dut, prog, checks, cycles=1600,
                   name="CALL/RET: return destination immediately calls again")
    checks.reg("first subroutine ran", 4, 0x444)
    checks.reg("second subroutine ran", 5, 0x555)
    checks.reg("second return continuation ran", 2, 0x222)
    checks.reg("RET-to-CALL wrong path flushed", 7, 0)
    checks.eq("SP restored after RET-to-CALL sequence",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)

    # Stack reuse with different saved return addresses, plus a preloaded
    # stale value at the next stack slot. A correct CALL must overwrite it.
    prog = [
        call(7),                    # 0 -> save 1 at 0x3fff
        load_imm(2, 0x111),         # 1
        call(9),                    # 2 -> save 3 at 0x3fff
        load_imm(3, 0x333),         # 3
        call(11),                   # 4 -> save 5 at 0x3fff
        load_imm(4, 0x444),         # 5
        jmp(13),                    # 6
        load_imm(5, 0x777),         # 7 function A
        ret(),                      # 8
        load_imm(6, 0x999),         # 9 function B
        ret(),                      # 10
        load_imm(8, 0xBBB),         # 11 function C
        ret(),                      # 12
        jmp(13),                    # 13 finish loop
    ]
    await run_case(dut, prog, checks, memory_init={0x3FFF: 0xBAD, 0x3FFE: 0xBAD},
                   cycles=1900, name="CALL/RET: stack slot reuse and stale data")
    checks.reg("first reused call returned", 2, 0x111)
    checks.reg("second reused call returned", 3, 0x333)
    checks.reg("third reused call returned", 4, 0x444)
    checks.reg("function A marker", 5, 0x777)
    checks.reg("function B marker", 6, 0x999)
    checks.reg("function C marker", 8, 0xBBB)
    checks.eq("SP restored after stack reuse",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    # Validate stack data through the CPU-visible cache path, not backing RAM.

    # General-purpose register clobbering in the callee must not corrupt
    # stack-based return flow. This deliberately does not require callee-save
    # semantics for those registers.
    prog = [
        call(4),                    # 0: return to 1
        load_imm(2, 0x222),         # 1: must execute
        jmp(7),                     # 2
        load_imm(7, 0xBAD),         # 3 wrong path
        load_imm(1, 0x111),         # 4 clobber caller-visible register
        load_imm(3, 0x333),         # 5 clobber another register
        ret(),                      # 6
        jmp(7),                     # 7 finish loop
    ]
    await run_case(dut, prog, checks, cycles=1100,
                   name="CALL/RET: callee register clobbering")
    checks.reg("callee register 1 changed", 1, 0x111)
    checks.reg("callee register 3 changed", 3, 0x333)
    checks.reg("return after register clobber", 2, 0x222)
    checks.reg("clobber test wrong path flushed", 7, 0)
    checks.eq("SP restored after register clobber",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)

    # Maximum supported nesting: 256 pushes fill 0x3fff down through 0x3f00.
    # Each function calls the next function and has RET at its continuation.
    # The deepest function RETs to the previous level's continuation, unwinding
    # all frames. This excludes an additional overflow attempt by design.
    depth = 256
    prog = [call(2), jmp(1)]  # main CALL, then halt-like safe loop at PC 1
    for level in range(depth - 1):
        call_pc = 2 + level * 2
        target_pc = call_pc + 2
        prog.append(call(target_pc))
        prog.append(ret())
    prog.append(ret())             # deepest function's RET
    # PC 1 is a loop, not a fall-through into function bodies.
    prog[1] = jmp(1)
    # CALL/RET plus cache/CDC traffic is much slower than one instruction per
    # cycle; allow enough fast-clock cycles for all 256 frames to unwind.
    await run_case(dut, prog, checks, cycles=200000,
                   name="CALL/RET: maximum supported stack depth (256)")
    checks.eq("SP restored after 256 nested calls",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    # Avoid raw backing-memory inspection: stack writes may still be resident
    # in cache depending on the implementation's write policy.

    # Reset while multiple CALL frames are outstanding. After reset, install a
    # harmless loop at PC 0 so execution cannot immediately build the stack
    # again; verify the architectural reset state.
    prog = [call(4), jmp(2), jmp(2), jmp(2), call(8), jmp(2), jmp(2), jmp(2), jmp(8)]
    await run_case(dut, prog, checks, cycles=20,
                   name="CALL/RET: enter nested calls before asynchronous reset")
    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0
    await edge_wait(dut.fast_clk, 8)
    await edge_wait(dut.slow_clk, 4)
    # Install a self-loop while reset is still asserted. Check reset state
    # before releasing reset, rather than after executing several instructions.
    dut.u_program_memory.mem[0].value = jmp(0)
    await edge_wait(dut.fast_clk, 2)
    checks.eq("SP reset during nested calls",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    # The CPU Lite specification does not define the PC's reset value.
    # Do not hard-code PC == 0 here: the current RTL presents 0xFFF while
    # reset is asserted, which may be an intentional pre-increment sentinel.
    # Validate PC reset behavior only after the RTL/spec contract defines it.
    dut.fast_rst_n.value = 1
    dut.slow_rst_n.value = 1
    await edge_wait(dut.fast_clk, 10)

    # CALL/RET plus full-width indirect data-memory diagnostic. Direct LOAD's
    # address is only 12 bits, so 0x3fff must be constructed in a register and
    # read with LOAD_IND. The stack's backing word should contain return PC 3
    # from the last sequential call in the preceding scenario.
    prog = [
        call(12),                   # 0: save 1
        load_imm(2, 0x111),         # 1
        call(15),                   # 2: save 3
        load_imm(3, 0x333),         # 3
        load_imm(11, 0xFFF),        # 4
        load_imm(12, 3),            # 5
        load_imm(13, 12),           # 6
        r_type(0x11, 12, 12, 13),   # 7: SHL R12,R12,R13 -> 0x3000
        add(11, 11, 12),            # 8: R11 = 0x3fff
        load_ind(6, 11),            # 9: R6 = MEM[0x3fff]
        jmp(18),                    # 10
        load_imm(7, 0xBAD),         # 11 wrong path
        load_imm(4, 0x444),         # 12 first subroutine
        ret(),                      # 13
        load_imm(7, 0xBAD),         # 14
        load_imm(5, 0x555),         # 15 second subroutine
        ret(),                      # 16
        load_imm(7, 0xBAD),         # 17
        jmp(18),                    # 18 finish loop
    ]
    await run_case(dut, prog, checks, cycles=1800,
                   name="CALL/RET: full-width stack memory diagnostic")
    checks.reg("first subroutine ran", 4, 0x444)
    checks.reg("first call returned", 2, 0x111)
    checks.reg("second subroutine ran", 5, 0x555)
    checks.reg("second call returned", 3, 0x333)
    checks.reg("sequential wrong path flushed", 7, 0)
    checks.eq("SP after sequential calls", sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.reg("link register after second call", 15, 3)
    # CPU-visible LOAD_IND below is authoritative; backing RAM may be stale.
    checks.reg("LOAD_IND diagnostic reads stack top", 6, 3)

    checks.summary()
    assert not checks.failed, (
        f"CPU pipeline stress regression failed: {len(checks.failed)} of "
        f"{checks.total} checks failed. See log above."
    )




