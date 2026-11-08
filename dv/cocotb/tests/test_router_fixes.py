# ==============================================================================
# Project Micro-NVSwitch: Rubin-Class High-Radix NoC Router for AI Fabrics
# Cocotb Regression Tests for Flow-Control / Routing Bug Fixes
#
# Uses a cycle-based environment with:
#   - credit-respecting upstream drivers (one per input port, VC-interleaved)
#   - downstream receiver models (depth-8 buffer per output VC) that flag any
#     credit overrun, packet interleaving on an output VC, or orphan flits
#   - an end-to-end scoreboard: every packet must arrive intact, in order, exactly
#     once at every destination in its mask, and all credits must be returned
#
# Tests:
# 1. test_body_flits_follow_own_header   - body flits keep their packet's route
#                                          when the next head is already queued
# 2. test_no_interleave_on_output_vc     - two packets on the same VC to the same
#                                          output are never interleaved
# 3. test_multicast_partial_grant        - multicast flit losing arbitration on
#                                          one output is not dropped there
# 4. test_multicast_zero_credit_dest     - multicast flit waits for a stalled dest
# 5. test_no_downstream_credit_overrun   - never sends more flits than credits
# 6. test_sharp_needs_both_operands      - SHARP only fires with both operands
# 7. test_random_traffic_scoreboard      - constrained-random mixed traffic
# ==============================================================================

import os
import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

NUM_PORTS = 8
NUM_VCS = 4
VC_DEPTH = 8
DATA_MASK = (1 << 64) - 1

HEAD, BODY, TAIL, SINGLE = 0b00, 0b01, 0b10, 0b11
TYPE_NAME = {HEAD: "HEAD", BODY: "BODY", TAIL: "TAIL", SINGLE: "SINGLE"}

SHARP_OP_NONE = 0b000
SHARP_OP_FP8_SUM = 0b001


def header_word(dest, src, pkt_id, sharp_op=SHARP_OP_NONE, payload=None):
    if payload is None:
        payload = random.getrandbits(40)
    return ((dest & 0xFF) << 56) | ((src & 0x7) << 53) | ((pkt_id & 0xFF) << 45) \
        | ((sharp_op & 0x7) << 42) | (payload & ((1 << 40) - 1))


def body_word(src, pkt_id, seq):
    # Body/tail flits carry the packet tag so the checkers can attribute them.
    return ((src & 0x7) << 61) | ((pkt_id & 0xFF) << 53) | ((seq & 0xFF) << 45) \
        | random.getrandbits(45)


def flit_tag(ftype, data):
    if ftype in (HEAD, SINGLE):
        return ((data >> 53) & 0x7, (data >> 45) & 0xFF)
    return ((data >> 61) & 0x7, (data >> 53) & 0xFF)


class Packet:
    _next_id = [0] * NUM_PORTS

    def __init__(self, src, vc, dest, length, sharp_op=SHARP_OP_NONE):
        assert dest != 0 and length >= 1
        self.src, self.vc, self.dest = src, vc, dest
        self.pkt_id = Packet._next_id[src]
        Packet._next_id[src] = (Packet._next_id[src] + 1) & 0xFF
        hdr = header_word(dest, src, self.pkt_id, sharp_op)
        if length == 1:
            self.flits = [(SINGLE, hdr)]
        else:
            self.flits = [(HEAD, hdr)]
            self.flits += [(BODY, body_word(src, self.pkt_id, i)) for i in range(1, length - 1)]
            self.flits.append((TAIL, body_word(src, self.pkt_id, length - 1)))


class RouterEnv:
    def __init__(self, dut, drain_prob=1.0):
        self.dut = dut
        self.drain_prob = drain_prob
        self.drain_enabled = [True] * NUM_PORTS
        self.tx = [[deque() for _ in range(NUM_VCS)] for _ in range(NUM_PORTS)]
        self.up_credits = [[VC_DEPTH] * NUM_VCS for _ in range(NUM_PORTS)]
        self.ds_buf = [[deque() for _ in range(NUM_VCS)] for _ in range(NUM_PORTS)]
        self.ds_open = [[None] * NUM_VCS for _ in range(NUM_PORTS)]
        self.expected = {}   # (out, src, pkt_id) -> [flits]
        self.received = {}   # (out, src, pkt_id) -> [flits]
        self.errors = []
        self.cycle = 0
        self.sharp_active_cycles = 0

    # ------------------------------------------------------------------ setup
    async def start(self):
        dut = self.dut
        Packet._next_id = [0] * NUM_PORTS
        cocotb.start_soon(Clock(dut.clk, 2, unit="ns").start())
        dut.rst_n.value = 0
        dut.i_flit_valid.value = 0
        dut.i_flit_type.value = 0
        dut.i_flit_vc.value = 0
        dut.i_flit_data.value = 0
        dut.i_credit_ret.value = 0
        for _ in range(3):
            await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.rst_n.value = 1
        cocotb.start_soon(self._run())

    def send(self, pkt):
        for f in pkt.flits:
            self.tx[pkt.src][pkt.vc].append(f)
        for o in range(NUM_PORTS):
            if (pkt.dest >> o) & 1:
                self.expected[(o, pkt.src, pkt.pkt_id)] = list(pkt.flits)
        return pkt

    def error(self, msg):
        self.errors.append(f"[cycle {self.cycle}] {msg}")
        self.dut._log.error(msg)

    # ------------------------------------------------------------- main loop
    async def _run(self):
        dut = self.dut
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            self.cycle += 1
            self._sample()
            await FallingEdge(dut.clk)
            self._drive()

    def _sample(self):
        dut = self.dut
        cred = int(dut.o_credit_ret.value)
        for p in range(NUM_PORTS):
            for v in range(NUM_VCS):
                if (cred >> (p * NUM_VCS + v)) & 1:
                    self.up_credits[p][v] += 1
                    if self.up_credits[p][v] > VC_DEPTH:
                        self.error(f"input {p} VC{v}: credit returned with no flit outstanding")
        if int(dut.o_sharp_active.value):
            self.sharp_active_cycles += 1

        valid = int(dut.o_flit_valid.value)
        if not valid:
            return
        types = int(dut.o_flit_type.value)
        vcs = int(dut.o_flit_vc.value)
        data = int(dut.o_flit_data.value)
        for o in range(NUM_PORTS):
            if (valid >> o) & 1:
                self._receive(o, (vcs >> (2 * o)) & 3, (types >> (2 * o)) & 3,
                              (data >> (64 * o)) & DATA_MASK)

    def _receive(self, o, vc, ftype, data):
        buf = self.ds_buf[o][vc]
        if len(buf) >= VC_DEPTH:
            self.error(f"output {o} VC{vc}: credit overrun, flit sent into a full downstream buffer")
        buf.append((ftype, data))

        tag = flit_tag(ftype, data)
        open_tag = self.ds_open[o][vc]
        if ftype == HEAD:
            if open_tag is not None:
                self.error(f"output {o} VC{vc}: HEAD of {tag} interleaved into open packet {open_tag}")
            self.ds_open[o][vc] = tag
        elif ftype == SINGLE:
            if open_tag is not None:
                self.error(f"output {o} VC{vc}: SINGLE {tag} interleaved into open packet {open_tag}")
        else:
            if open_tag != tag:
                self.error(f"output {o} VC{vc}: {TYPE_NAME[ftype]} of {tag} arrived while open packet is {open_tag}")
            if ftype == TAIL:
                self.ds_open[o][vc] = None

        key = (o,) + tag
        if key not in self.expected:
            self.error(f"output {o}: unexpected flit {TYPE_NAME[ftype]} of packet {tag} (misrouted)")
        self.received.setdefault(key, []).append((ftype, data))

    def _drive(self):
        dut = self.dut
        cr = 0
        for o in range(NUM_PORTS):
            if not self.drain_enabled[o]:
                continue
            for v in range(NUM_VCS):
                if self.ds_buf[o][v] and random.random() < self.drain_prob:
                    self.ds_buf[o][v].popleft()
                    cr |= 1 << (o * NUM_VCS + v)
        dut.i_credit_ret.value = cr

        valid = types = vcs = data = 0
        for p in range(NUM_PORTS):
            ready = [v for v in range(NUM_VCS) if self.tx[p][v] and self.up_credits[p][v] > 0]
            if not ready:
                continue
            v = random.choice(ready)
            ftype, fdata = self.tx[p][v].popleft()
            self.up_credits[p][v] -= 1
            valid |= 1 << p
            types |= ftype << (2 * p)
            vcs |= v << (2 * p)
            data |= fdata << (64 * p)
        dut.i_flit_valid.value = valid
        dut.i_flit_type.value = types
        dut.i_flit_vc.value = vcs
        dut.i_flit_data.value = data

    # ------------------------------------------------------------- helpers
    async def cycles(self, n):
        for _ in range(n):
            await RisingEdge(self.dut.clk)

    def tx_idle(self):
        return all(not q for port in self.tx for q in port)

    def all_delivered(self):
        return all(len(self.received.get(k, [])) >= len(v) for k, v in self.expected.items())

    async def finish(self, timeout=2000):
        # Re-open every sink so all traffic can drain, then wait for delivery.
        self.drain_enabled = [True] * NUM_PORTS
        for _ in range(timeout):
            if self.tx_idle() and self.all_delivered():
                break
            await RisingEdge(self.dut.clk)
        # Let credits come home and catch any late duplicate/misrouted flits.
        self.drain_prob = 1.0
        await self.cycles(40)
        self.check()

    def check(self):
        errs = list(self.errors)
        for key, flits in self.expected.items():
            got = self.received.get(key, [])
            if got != flits:
                errs.append(f"output {key[0]}: packet src={key[1]} id={key[2]} expected "
                            f"{[TYPE_NAME[t] for t, _ in flits]}, received "
                            f"{[TYPE_NAME[t] for t, _ in got]}"
                            + ("" if [t for t, _ in got] != [t for t, _ in flits] else " (data mismatch)"))
        for p in range(NUM_PORTS):
            for v in range(NUM_VCS):
                if self.up_credits[p][v] != VC_DEPTH:
                    errs.append(f"input {p} VC{v}: {VC_DEPTH - self.up_credits[p][v]} upstream credits never returned")
        assert not errs, "Scoreboard failures:\n  " + "\n  ".join(errs[:20])


# ==============================================================================
# Directed tests
# ==============================================================================

@cocotb.test()
async def test_body_flits_follow_own_header(dut):
    """Packet B's head is queued behind packet A's body; A's body must still go to A's output."""
    random.seed(1)
    env = RouterEnv(dut)
    await env.start()

    # Port 1 floods output 3 on another VC so port 0 drains at ~half rate and builds a backlog.
    for _ in range(4):
        env.send(Packet(src=1, vc=1, dest=1 << 3, length=4))
    env.send(Packet(src=0, vc=0, dest=1 << 3, length=8))   # packet A -> output 3
    env.send(Packet(src=0, vc=0, dest=1 << 5, length=3))   # packet B -> output 5

    await env.finish()


@cocotb.test()
async def test_no_interleave_on_output_vc(dut):
    """Two inputs send multi-flit packets on VC0 to the same output at the same time."""
    random.seed(2)
    env = RouterEnv(dut)
    await env.start()

    env.send(Packet(src=0, vc=0, dest=1 << 2, length=4))
    env.send(Packet(src=1, vc=0, dest=1 << 2, length=4))

    await env.finish()


@cocotb.test()
async def test_multicast_partial_grant(dut):
    """Multicast {2,3} from port 4 loses output 3 to port 3 in the same cycle; output 3 must still get it."""
    random.seed(3)
    env = RouterEnv(dut)
    await env.start()

    env.send(Packet(src=3, vc=0, dest=1 << 3, length=1))
    env.send(Packet(src=4, vc=1, dest=(1 << 2) | (1 << 3), length=1))

    await env.finish()


@cocotb.test()
async def test_multicast_zero_credit_dest(dut):
    """Multicast {1,7} while output 7 VC0 has no credits: it must wait, then deliver to both."""
    random.seed(4)
    env = RouterEnv(dut)
    await env.start()

    # Fill output 7 VC0's downstream buffer (spaced out so only credit exhaustion matters).
    env.drain_enabled[7] = False
    for _ in range(VC_DEPTH):
        env.send(Packet(src=5, vc=0, dest=1 << 7, length=1))
        await env.cycles(4)

    env.send(Packet(src=6, vc=0, dest=(1 << 1) | (1 << 7), length=1))
    await env.cycles(20)
    assert (7, 6, 0) not in env.received, "multicast sent to output 7 with zero credits"

    env.drain_enabled[7] = True
    await env.finish()


@cocotb.test()
async def test_no_downstream_credit_overrun(dut):
    """Ten back-to-back flits to a stalled output: exactly 8 may leave until credits return."""
    random.seed(5)
    env = RouterEnv(dut)
    await env.start()

    env.drain_enabled[5] = False
    for _ in range(10):
        env.send(Packet(src=0, vc=0, dest=1 << 5, length=1))
    await env.cycles(40)

    sent = sum(len(v) for k, v in env.received.items() if k[0] == 5)
    assert sent == VC_DEPTH, f"expected exactly {VC_DEPTH} flits while stalled, saw {sent}"

    env.drain_enabled[5] = True
    await env.finish()


@cocotb.test()
async def test_sharp_needs_both_operands(dut):
    """SHARP must not fire on port 0 alone (operand B invalid); it must fire when both are present."""
    random.seed(6)
    env = RouterEnv(dut)
    await env.start()

    env.send(Packet(src=0, vc=0, dest=1 << 2, length=1, sharp_op=SHARP_OP_FP8_SUM))
    await env.cycles(10)
    assert env.sharp_active_cycles == 0, "SHARP fired with no valid operand on port 1"

    env.send(Packet(src=0, vc=0, dest=1 << 2, length=1, sharp_op=SHARP_OP_FP8_SUM))
    env.send(Packet(src=1, vc=0, dest=1 << 3, length=1))
    await env.cycles(10)
    assert env.sharp_active_cycles > 0, "SHARP did not fire with both operands present"

    await env.finish()


# ==============================================================================
# Constrained-random stress
# ==============================================================================

@cocotb.test()
async def test_random_traffic_scoreboard(dut):
    """Random unicast/multicast wormhole traffic on all ports and VCs with bursty downstream stalls."""
    seed = int(os.environ.get("TRAFFIC_SEED", random.randrange(1 << 30)))
    dut._log.info(f"random seed = {seed}")
    random.seed(seed)
    env = RouterEnv(dut, drain_prob=0.6)
    await env.start()

    for src in range(NUM_PORTS):
        for _ in range(30):
            if random.random() < 0.7:
                dest = 1 << random.randrange(NUM_PORTS)
            else:
                dest = random.randrange(1, 1 << NUM_PORTS)
            env.send(Packet(src=src, vc=random.randrange(NUM_VCS), dest=dest,
                            length=random.randint(1, 5)))

    # Random per-output stall bursts while traffic is flowing.
    for _ in range(150):
        o = random.randrange(NUM_PORTS)
        env.drain_enabled[o] = not env.drain_enabled[o]
        await env.cycles(random.randint(1, 6))

    await env.finish(timeout=5000)
