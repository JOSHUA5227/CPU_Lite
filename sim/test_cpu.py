import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

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
OP_SHL       = 0x11
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
    return r_type(OP_STORE_IND, data_rd, 0, address_rs)


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


def loop_program(instructions, loop_addr=None):
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
            msg = (
                f"{label}: actual=0x{actual:08x}, "
                f"expected=0x{expected:08x}"
            )
            self.failed.append(msg)
            self.dut._log.error("FAIL %s", msg)
        else:
            self.dut._log.info(
                "PASS %-55s 0x%08x", label, actual
            )

    def reg(self, label, index, expected):
        self.eq(
            f"{label} (R{index})",
            get_reg(self.dut, index),
            expected & MASK32
        )

    def mem(self, label, address, expected):
        self.eq(
            f"{label} (MEM[{address:#05x}])",
            get_mem(self.dut, address),
            expected & MASK32
        )

    def summary(self):
        self.dut._log.info("=" * 72)
        self.dut._log.info(
            "COCOTB CPU STRESS SUMMARY: %d checks, %d passed, %d failed",
            self.total, self.total - len(self.failed), len(self.failed)
        )
        for failure in self.failed:
            self.dut._log.error("FAILED: %s", failure)
        self.dut._log.info("=" * 72)


async def edge_wait(clk, cycles=1):
    for _ in range(cycles):
        await RisingEdge(clk)
        await Timer(1, unit="ns")


async def reset_and_load(dut, program, memory_init=None):
    dut.fast_rst_n.value = 0
    dut.slow_rst_n.value = 0

    await edge_wait(dut.fast_clk, 8)
    await edge_wait(dut.slow_clk, 4)

    pmem = dut.u_program_memory.mem
    dmem = dut.u_data_memory.mem

    for i in range(128):
        pmem[i].value = 0

    for i in range(1024):
        dmem[i].value = 0

    for address, instruction in enumerate(program):
        if address >= 128:
            raise ValueError("Test program exceeds cleared program range")
        pmem[address].value = instruction & MASK32

    if memory_init:
        for address, value in memory_init.items():
            dmem[address].value = value & MASK32

    await edge_wait(dut.fast_clk, 2)
    dut.fast_rst_n.value = 1
    dut.slow_rst_n.value = 1
    await edge_wait(dut.fast_clk, 5)


async def run_case(
    dut, program, checks, memory_init=None,
    cycles=500, name="scenario"
):
    dut._log.info("")
    dut._log.info("----- %s -----", name)
    await reset_and_load(dut, program, memory_init)
    await edge_wait(dut.fast_clk, cycles)


def branch_program(op, init1, init2):
    return loop_program([
        init1,
        init2,
        cmp(1, 2),
        branch(op, 7),
        load_imm(4, 0xBAD),
        load_imm(3, 0x111),
        jmp(10),
        load_imm(3, 0x222),
        load_imm(5, 0x456),
        jmp(10),
    ], loop_addr=10)


@cocotb.test()
async def test_cpu_pipeline_stress(dut):
    cocotb.start_soon(
        Clock(dut.fast_clk, 6.666, unit="ns").start()
    )
    cocotb.start_soon(
        Clock(dut.slow_clk, 14.286, unit="ns").start()
    )

    checks = Checks(dut)

    # ================================================================
    # 1. PIPELINE HAZARDS / DEPENDENCIES
    # ================================================================

    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        add(3, 1, 2),
        i_type(OP_ADDI, 4, 3, 5),
        add(5, 4, 1),
        xor(6, 5, 3),
    ])

    await run_case(
        dut, prog, checks,
        {0x100: 0x123, 0x101: 0x456},
        1800, "HAZARD: load operands and dependency chain"
    )

    checks.reg("load source A", 1, 0x123)
    checks.reg("load source B", 2, 0x456)
    checks.reg("ADD dependent on loads", 3, 0x579)
    checks.reg("ADDI dependent on ADD", 4, 0x57E)
    checks.reg("ADD dependent on ADDI", 5, 0x6A1)
    checks.reg("XOR dependency", 6, 0x6A1 ^ 0x579)

    prog = loop_program([
        load(1, 0x110),
        i_type(OP_ADDI, 2, 1, 7),
        store(1, 0x210),
        load(3, 0x210),
        add(4, 2, 3),
    ])

    await run_case(
        dut, prog, checks, {0x110: 0x222},
        1800, "HAZARD: load-use and dependent store"
    )

    checks.reg("load source", 1, 0x222)
    checks.reg("ADDI after load", 2, 0x229)
    checks.reg("load after store", 3, 0x222)
    checks.reg("ADD dependent on loaded values", 4, 0x44B)
    checks.mem("stored forwarded value", 0x210, 0x222)

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

    await run_case(
        dut, prog, checks,
        {0x120: 0xA1A1, 0x121: 0xB2B2, 0x122: 0xC3C3},
        2200, "HAZARD: consecutive loads and stores"
    )

    for reg, expected in [
        (1, 0xA1A1), (2, 0xB2B2), (3, 0xC3C3),
        (4, 0xA1A1), (5, 0xB2B2), (6, 0xC3C3)
    ]:
        checks.reg("consecutive load/store result", reg, expected)

    for addr, expected in [
        (0x220, 0xA1A1), (0x221, 0xB2B2), (0x222, 0xC3C3)
    ]:
        checks.mem("stored word", addr, expected)

    # ================================================================
    # 2. CACHE HITS, MISSES, CONFLICTS AND WRITE-BACK
    # ================================================================

    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        load(3, 0x102),
        load(4, 0x103),
        load(5, 0x100),
        load(6, 0x103),
        load_imm(7, 0x777),
        store(7, 0x101),
        load(8, 0x101),
        load(9, 0x100),
        load(10, 0x102),
    ])

    await run_case(
        dut, prog, checks,
        {
            0x100: 0x11111111,
            0x101: 0x22222222,
            0x102: 0x33333333,
            0x103: 0x44444444,
        },
        2200, "CACHE: refill, hits and dirty write hit"
    )

    for reg, expected in [
        (1, 0x11111111), (2, 0x22222222),
        (3, 0x33333333), (4, 0x44444444),
        (5, 0x11111111), (6, 0x44444444),
        (8, 0x777), (9, 0x11111111), (10, 0x33333333)
    ]:
        checks.reg("cache read result", reg, expected)

    prog = loop_program([
        load(1, 0x100),
        load(2, 0x101),
        load_imm(3, 0x555),
        store(3, 0x100),
        load_imm(4, 0x666),
        store(4, 0x102),
        load(5, 0x120),
        load(6, 0x100),
        load(7, 0x101),
        load(8, 0x102),
        load(9, 0x103),
    ])

    init = {
        0x100: 0xAAAA0000, 0x101: 0xBBBB0001,
        0x102: 0xCCCC0002, 0x103: 0xDDDD0003,
        0x120: 0x12345678, 0x121: 0x21212121,
        0x122: 0x32323232, 0x123: 0x43434343,
    }

    await run_case(
        dut, prog, checks, init, 3000,
        "CACHE: conflicting lines and dirty eviction"
    )

    for reg, expected in [
        (5, 0x12345678), (6, 0x555),
        (7, 0xBBBB0001), (8, 0x666), (9, 0xDDDD0003)
    ]:
        checks.reg("conflict and write-back result", reg, expected)

    for addr, expected in [
        (0x100, 0x555), (0x101, 0xBBBB0001),
        (0x102, 0x666), (0x103, 0xDDDD0003)
    ]:
        checks.mem("write-back result", addr, expected)

    prog = loop_program([
        load(1, 0x140),
        load(2, 0x160),
        load(3, 0x140),
        load(4, 0x160),
        load(5, 0x141),
        load(6, 0x161),
    ])

    await run_case(
        dut, prog, checks,
        {
            0x140: 0x14001400, 0x141: 0x14101410,
            0x160: 0x16001600, 0x161: 0x16101610
        },
        2600, "CACHE: repeated conflict misses"
    )

    for reg, expected in [
        (1, 0x14001400), (2, 0x16001600),
        (3, 0x14001400), (4, 0x16001600),
        (5, 0x14101410), (6, 0x16101610)
    ]:
        checks.reg("conflict miss result", reg, expected)

    # ================================================================
    # 3. CONTROL FLOW / FLUSHING
    # ================================================================

    prog = loop_program([
        jmp(4),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
    ])

    await run_case(dut, prog, checks, cycles=350, name="CONTROL: JMP")
    checks.reg("JMP wrong path flushed", 4, 0)
    checks.reg("JMP target", 3, 0x321)
    checks.reg("JMP successor", 5, 0x456)

    for condition, initial in [
        ("taken", 1), ("not taken", 0)
    ]:
        prog = loop_program([
            load_imm(1, initial),
            jmp_if(1, 4),
            load_imm(4, 0xBAD),
            jmp(7),
            load_imm(3, 0x321),
            load_imm(5, 0x456),
            jmp(7),
        ], loop_addr=7)

        await run_case(
            dut, prog, checks, cycles=350,
            name=f"CONTROL: JMP_IF {condition}"
        )

        if initial:
            checks.reg("JMP_IF wrong path", 4, 0)
            checks.reg("JMP_IF target", 3, 0x321)
            checks.reg("JMP_IF successor", 5, 0x456)
        else:
            checks.reg("JMP_IF fall-through", 4, 0xBAD)
            checks.reg("JMP_IF target skipped", 3, 0)
            checks.reg("JMP_IF successor skipped", 5, 0)

    prog = loop_program([
        load_imm(1, 5),
        jmp_reg(1),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(4, 0xBAD),
        load_imm(3, 0x321),
        load_imm(5, 0x456),
    ])

    await run_case(
        dut, prog, checks, cycles=350,
        name="CONTROL: JMP_REG"
    )

    checks.reg("JMP_REG wrong path", 4, 0)
    checks.reg("JMP_REG target", 3, 0x321)
    checks.reg("JMP_REG successor", 5, 0x456)

    branch_cases = [
        ("BEQ taken", OP_BEQ, load_imm(1, 5), load_imm(2, 5), True),
        ("BEQ not taken", OP_BEQ, load_imm(1, 5), load_imm(2, 6), False),
        ("BNE taken", OP_BNE, load_imm(1, 5), load_imm(2, 6), True),
        ("BNE not taken", OP_BNE, load_imm(1, 5), load_imm(2, 5), False),
        ("BLT taken", OP_BLT, load_imm(1, 1), load_imm(2, 2), True),
        ("BLT not taken", OP_BLT, load_imm(1, 2), load_imm(2, 1), False),
        ("BGE taken", OP_BGE, load_imm(1, 2), load_imm(2, 1), True),
        ("BGE not taken", OP_BGE, load_imm(1, 1), load_imm(2, 2), False),
        ("BLTU taken", OP_BLTU, load_imm(1, 1), load_imm(2, 2), True),
        ("BLTU not taken", OP_BLTU, load_imm(1, 2), load_imm(2, 1), False),
        ("BGEU taken", OP_BGEU, load_imm(1, 2), load_imm(2, 1), True),
        ("BGEU not taken", OP_BGEU, load_imm(1, 1), load_imm(2, 2), False),
        ("BLT signed negative", OP_BLT, lui(1, 0xFFF), load_imm(2, 1), True),
        ("BLTU unsigned large", OP_BLTU, lui(1, 0xFFF), load_imm(2, 1), False),
        ("BGE signed negative", OP_BGE, lui(1, 0xFFF), load_imm(2, 1), False),
        ("BGEU unsigned large", OP_BGEU, lui(1, 0xFFF), load_imm(2, 1), True),
    ]

    for name, op, init1, init2, taken in branch_cases:
        await run_case(
            dut, branch_program(op, init1, init2), checks,
            cycles=450, name=f"CONTROL: {name}"
        )

        if taken:
            checks.reg(f"{name}: wrong path", 4, 0)
            checks.reg(f"{name}: target", 3, 0x222)
            checks.reg(f"{name}: successor", 5, 0x456)
        else:
            checks.reg(f"{name}: fall-through", 4, 0xBAD)
            checks.reg(f"{name}: not-taken marker", 3, 0x111)
            checks.reg(f"{name}: target skipped", 5, 0)

    # ================================================================
    # 4. CALL / RET
    # ================================================================

    prog = [
        call(4),
        load_imm(2, 0x111),
        jmp(7),
        load_imm(7, 0xBAD),
        load_imm(3, 0x222),
        ret(),
        load_imm(7, 0xBAD),
        jmp(7),
    ]

    await run_case(
        dut, prog, checks, cycles=900,
        name="CALL/RET: simple call"
    )

    checks.reg("CALL return path", 2, 0x111)
    checks.reg("CALL subroutine", 3, 0x222)
    checks.reg("CALL wrong path", 7, 0)
    checks.reg("R15 after RET", 15, 1)
    checks.eq("stack pointer after RET",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.mem("CALL saved return address", 0x3FFF, 1)

    prog = [
        call(4),
        load_imm(2, 0x111),
        jmp(12),
        load_imm(7, 0xBAD),
        load_imm(4, 0x444),
        call(8),
        load_imm(5, 0x555),
        ret(),
        load_imm(6, 0x666),
        ret(),
        load_imm(7, 0xBAD),
        load_imm(7, 0xBAD),
        jmp(12),
    ]

    await run_case(
        dut, prog, checks, cycles=1400,
        name="CALL/RET: nested calls"
    )

    checks.reg("outer function", 4, 0x444)
    checks.reg("inner function", 6, 0x666)
    checks.reg("inner return to outer", 5, 0x555)
    checks.reg("outer return to main", 2, 0x111)
    checks.reg("nested wrong path", 7, 0)
    checks.eq("stack pointer after nested RETs",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.mem("outer return address", 0x3FFF, 1)
    checks.mem("inner return address", 0x3FFE, 6)

    # ------------------------------------------------
    # Sequential calls + corrected full-address LOAD.
    #
    # The diagnostic is in the SAME program as the calls.
    # No reset occurs between the calls and diagnostic LOAD.
    #
    # R11 = 0xFFF + (3 << 12) = 0x3FFF
    # LOAD_IND uses the full register address.
    # ------------------------------------------------

    prog = [
        call(12),                   # 0: save return address 1
        load_imm(2, 0x111),         # 1: first return marker
        call(15),                   # 2: save return address 3
        load_imm(3, 0x333),         # 3: second return marker

        load_imm(11, 0xFFF),        # 4: low 12 address bits
        load_imm(12, 3),            # 5: upper address bits
        load_imm(13, 12),           # 6: shift amount
        r_type(OP_SHL, 12, 12, 13), # 7: R12 = 0x3000
        add(11, 11, 12),            # 8: R11 = 0x3FFF
        load_ind(6, 11),            # 9: CPU/cache diagnostic LOAD
        jmp(18),                    # 10: finish
        load_imm(7, 0xBAD),         # 11: must not execute

        load_imm(4, 0x444),         # 12: first subroutine
        ret(),                      # 13: return to PC 1
        load_imm(7, 0xBAD),         # 14: must not execute

        load_imm(5, 0x555),         # 15: second subroutine
        ret(),                      # 16: return to PC 3
        load_imm(7, 0xBAD),         # 17: must not execute

        jmp(18),                    # 18: finish loop
    ]

    await run_case(
        dut, prog, checks, cycles=1600,
        name="CALL/RET: sequential calls + cache diagnostic"
    )

    checks.reg("first subroutine ran", 4, 0x444)
    checks.reg("first call returned", 2, 0x111)
    checks.reg("second subroutine ran", 5, 0x555)
    checks.reg("second call returned", 3, 0x333)
    checks.reg("sequential wrong path flushed", 7, 0)
    checks.eq("stack pointer after sequential calls",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)
    checks.reg("R15 after second call", 15, 3)

    # Read R6 after sufficient execution time for the LOAD/CDC path.
    diagnostic_value = get_reg(dut, 6)
    checks.eq("CACHE DIAGNOSTIC: LOAD_IND [0x3FFF]",
              diagnostic_value, 3)

    if diagnostic_value == 3:
        dut._log.info(
            "DIAGNOSTIC: CPU LOAD returned 3; "
            "the CPU-visible data matches the expected value."
        )
    elif diagnostic_value == 1:
        dut._log.error(
            "DIAGNOSTIC: CPU LOAD returned 1; "
            "investigate cache write-hit handling."
        )
    else:
        dut._log.error(
            "DIAGNOSTIC: CPU LOAD returned 0x%08x, expected 3. "
            "Investigate indirect addressing, cache state, "
            "pipeline completion, and CDC timing.",
            diagnostic_value
        )

    # Immediate return.
    prog = [
        call(3),
        load_imm(2, 0x222),
        jmp(5),
        ret(),
        load_imm(7, 0xBAD),
        jmp(5),
    ]

    await run_case(
        dut, prog, checks, cycles=900,
        name="CALL/RET: immediate return"
    )

    checks.reg("immediate RET returned to caller", 2, 0x222)
    checks.reg("immediate RET flushed fall-through", 7, 0)
    checks.reg("immediate RET restored link register", 15, 1)
    checks.eq("stack pointer after immediate RET",
              sig_value(dut.u_cpu_core.stack_pointer), 0x3FFF)

    checks.summary()

    assert not checks.failed, (
        f"CPU pipeline stress regression failed: "
        f"{len(checks.failed)} of {checks.total} checks failed. "
        "See log above."
    )
