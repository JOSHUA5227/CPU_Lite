module cpu_core_pipelined#(
parameter PROG_ADDR_WIDTH = 12,
parameter DATA_ADDR_WIDTH = 14,
parameter DATA_WIDTH = 32,
parameter STACK_LIMIT = 14'h3F00
)(

input wire clk,
input wire rst_n,

// program memory ports
input wire [DATA_WIDTH-1:0] instruction,
output wire [PROG_ADDR_WIDTH-1:0] program_count,

//Cache Ports
input wire [DATA_WIDTH-1:0] rdata,
input wire cpu_ready,

output reg cpu_req,
output reg read_write,
output reg [DATA_ADDR_WIDTH-1:0] addr,
output reg [DATA_WIDTH-1:0] wdata
);
localparam STACK_START = 14'h3FFF;

localparam NOP = 8'h00;
localparam LOAD = 8'h01;
localparam LOAD_IND = 8'h02;
localparam LOAD_IMM = 8'h03;
localparam STORE = 8'h04;
localparam STORE_IND = 8'h05;
localparam ADD = 8'h06;
localparam SUB = 8'h07;
localparam MUL = 8'h08;
localparam OP_AND = 8'h09;
localparam OP_OR = 8'h0A;
localparam OP_NOT = 8'h0B;
localparam CMP = 8'h0C;
localparam EQ = 8'h0D;
localparam ADDI = 8'h16;
localparam SUBI = 8'h17;
localparam SHL = 8'h11;
localparam SHR = 8'h12;
localparam SAR = 8'h13;
localparam JMP = 8'h0E;
localparam JMP_IF = 8'h0F;
localparam BEQ = 8'h20;
localparam BNE = 8'h21;
localparam BLT = 8'h22;
localparam BGE = 8'h23;
localparam HALT = 8'hFF;
localparam OP_XOR = 8'h10;
localparam OP_ROL = 8'h14;
localparam OP_ROR = 8'h15;
localparam ANDI = 8'h18;
localparam ORI = 8'h19;
localparam XORI = 8'h1A;
localparam MOV = 8'h1B;
localparam SLT = 8'h1C;
localparam SLTU = 8'h1D;
localparam LUI = 8'h1E;
localparam BLTU = 8'h24;
localparam BGEU = 8'h25;
localparam JMP_REG = 8'h26;
localparam CALL = 8'h27;
localparam RET = 8'h28;


reg [DATA_WIDTH-1:0] R [0:15];
reg [3:0] psr;
reg [PROG_ADDR_WIDTH-1:0] pc;


// FETCH/DECODE Registers
reg [PROG_ADDR_WIDTH-1:0] fetch_pc;

reg [DATA_WIDTH-1:0] fetch_instruct;
reg fetch_valid;

// DECODE/EXECUTE Registers
reg [PROG_ADDR_WIDTH-1:0] decode_pc;
reg [DATA_WIDTH-1:0] decode_instruct;
wire [3:0] decode_rs1,decode_rs2,decode_rd;
wire [7:0] decode_opcode;
wire [11:0] decode_imm;

assign {decode_opcode,decode_rd,decode_rs1,decode_rs2,decode_imm} = decode_instruct;

reg [DATA_WIDTH-1:0] decode_op_a,decode_op_b;
reg decode_valid;

// EXECUTE/MEMORY Registers
reg [PROG_ADDR_WIDTH-1:0] exe_pc;
reg [7:0] exe_opcode;
reg [3:0] exe_rs1,exe_rs2,exe_rd;
reg [11:0] exe_imm;

reg exe_read;
reg exe_write;

reg [DATA_WIDTH-1:0] exe_op_a,exe_op_b;
reg [2*DATA_WIDTH-1:0] exe_alu_res;
reg [DATA_WIDTH-1:0] exe_result_op; // NON alu operations if needed
reg exe_valid;
// MEMORY/WRITEBACK Registers
reg [DATA_WIDTH-1:0] mem_res_reg;
reg [DATA_WIDTH-1:0] mem_destination_reg;
reg mem_valid;



//Fetch Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    fetch_pc <= 0;
    fetch_instruct <= 0;
    fetch_valid <= 0;
  end
  else
  begin
    fetch_instruct <= instruction;
    fetch_valid <= (fetch_en) ? 1 : 0;
    fetch_pc <= pc;
  end
end

//Decode Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    decode_pc <= 0;
    decode_instruct <= 0;
    decode_valid <= 0;
  end
  else
  begin
    decode_pc <= fetch_pc;
    decode_instruct <= fetch_instruct;
    decode_valid <= (decode_en) ? 1 : 0;
  end
end

always@(*)
begin
   decode_op_a = R[decode_rs1];
   case(decode_opcode)
   ADD,SUB,MUL,OP_AND,OP_OR,CMP,EQ,OP_XOR,SLT,SLTU: decode_op_b = R[decode_rs2];
   OP_NOT: decode_op_b = 0;
   ADDI,SUBI: decode_op_b = { {DATA_WIDTH-12{decode_imm[11]}},decode_imm};
   SHL,SHR,SAR,OP_ROL,OP_ROR:decode_op_b = { {DATA_WIDTH-5{1'b0}}, R[decode_rs2][4:0]};
   ANDI,ORI,XORI: decode_op_b = { {DATA_WIDTH-12{1'b0}},decode_imm};
   default:
   begin
      decode_op_b = 0;
   end
   endcase
end


//Execute Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    exe_pc <= 0;
    exe_opcode <= 0;
    exe_rs1 <= 0;
    exe_rs2 <= 0;
    exe_rd <= 0;
    exe_imm <= 0; 
    
    exe_op_a <= 0;
    exe_op_b <= 0;
    exe_valid <= 0;
  end
  else
  begin
    exe_pc <= decode_pc;
    exe_opcode <= decode_opcode;
    exe_rs1 <= decode_rs1;
    exe_rs2 <= decode_rs2;
    exe_rd <= decode_rd;
    exe_imm <= decode_imm;
    
    exe_op_a <= decode_op_a;
    exe_op_b <= decode_op_b;
    exe_valid <= (exe_en) ? 1 : 0;
  end
end
always@(*)
begin
  exe_alu_res = 0;
  Z = 0;
  N = 0;
  C = 0;
  V = 0;
  case(exe_opcode)
  ADD,ADDI:
  begin
    {C, exe_alu_res[31:0]} = {1'b0, exe_op_a} + {1'b0, exe_op_b};
    Z = exe_alu_res == 0;
    N = exe_alu_res[31];
    V = ( ~(exe_op_a[31] ^ exe_op_b[31]) ) & (exe_alu_res[31] ^ exe_op_a[31]); 
  end
  SUB,SUBI,CMP:
  begin
    exe_alu_res[32:0] = exe_op_a - exe_op_b;
    C = exe_op_a >= exe_op_b;
    Z = exe_alu_res == 0;
    N = exe_alu_res[31];
    V = ( (exe_op_a[31] ^ exe_op_b[31]) ) & (exe_alu_res[31] ^ exe_op_a[31]); 
  end
  MUL:
  begin
      exe_alu_res = exe_op_a * exe_op_b;
      Z = (exe_alu_res[31:0] == 0);
      N = exe_alu_res[31];
  end
  OP_AND,ANDI:
  begin
    exe_alu_res[31:0] = exe_op_a & exe_op_b;
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  OP_OR,ORI:
  begin
    exe_alu_res[31:0] = exe_op_a | exe_op_b;
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  OP_XOR,XORI:
  begin
    exe_alu_res[31:0] = exe_op_a ^ exe_op_b;
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  OP_NOT:
  begin
    exe_alu_res[31:0] = ~exe_op_a;
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end


  SHL:
  begin
    exe_alu_res[31:0] = exe_op_a << exe_op_b[4:0];
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  SHR:
  begin
    exe_alu_res[31:0] = exe_op_a >> exe_op_b[4:0];
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  SAR:
  begin
    exe_alu_res[31:0] = $signed(exe_op_a) >>> exe_op_b[4:0];
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end
  
  OP_ROL:
  begin
      if(exe_op_b[4:0] == 0)
        exe_alu_res[31:0] = exe_op_a;
      else
        exe_alu_res[31:0] = (exe_op_a << exe_op_b[4:0]) | (exe_op_a >> ( 32- exe_op_b[4:0]));
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  OP_ROR:
  begin
      if(exe_op_b[4:0] == 0)
        exe_alu_res[31:0] = exe_op_a;
      else
        exe_alu_res[31:0] = (exe_op_a >> exe_op_b[4:0]) | (exe_op_a << ( 32- exe_op_b[4:0]));

    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
  end

  EQ:
  begin
    exe_alu_res[31:0] = (exe_op_a == exe_op_b) ? 1 : 0;
    
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
    C = 0;
    V = 0;
  end


  SLT:
  begin
    exe_alu_res[31:0] = ( $signed(exe_op_a) < $signed(exe_op_b)) ? 1 : 0;
    
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
    C = 0;
    V = 0;
  end


  SLTU:
  begin
    exe_alu_res[31:0] = ( exe_op_a < exe_op_b) ? 1 : 0;
    
    Z = exe_alu_res[31:0] == 0;
    N = exe_alu_res[31];
    C = 0;
    V = 0;
  end
  
  default:
  begin
    exe_alu_res = 0;
    N = 0;
    C = 0;
    V = 0;
  end
  endcase
end

//Non ALU operations
always@(*)
begin
  case(exe_opcode)
  LOAD_IMM:exe_result_op = {{DATA_WIDTH-12{1'b0}},exe_imm};
  MOV: exe_result_op = exe_op_a;
  LUI: exe_result_op = {exe_imm,20'b0};
  default: exe_result_op = 0;
  endcase
end


endmodule
