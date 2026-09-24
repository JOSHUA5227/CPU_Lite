module cpu_core#(
parameter PROG_ADDR_WIDTH = 12,
parameter DATA_ADDR_WIDTH = 14,
parameter DATA_WIDTH = 32
)(

input wire clk,
input wire rst_n,

// program memory ports
input wire [DATA_WIDTH-1:0] instruction,
output reg [PROG_ADDR_WIDTH-1:0] pc,

//Cache Ports
input wire [DATA_WIDTH-1:0] rdata,
input wire cpu_ready,

output reg cpu_req,
output reg read_write,
output reg [DATA_ADDR_WIDTH-1:0] addr,
output reg [DATA_WIDTH-1:0] wdata
);

localparam RESET = 3'd0;
localparam FETCH = 3'd1;
localparam DECODE = 3'd2;
localparam EXECUTE = 3'd3;
localparam EXECUTE_WAIT = 3'd4;
localparam MEMORY = 3'd5;
localparam WRITEBACK = 3'd6;
localparam HLT = 3'd7;

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
localparam ROL = 8'h14;
localparam ROR = 8'h15;
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


reg [3:0] psr;
reg [DATA_WIDTH-1:0] R [0:15];

reg Z,N,C,V;
reg [DATA_WIDTH-1:0] op_a,op_b;
reg [DATA_WIDTH-1:0] result_op;

reg [DATA_WIDTH-1:0] reg_rdata;

reg [2*DATA_WIDTH-1:0] alu_res;
reg [2:0] present_state,next_state;

reg [DATA_WIDTH-1:0] instruction_reg;

wire [3:0] rd,rs1,rs2;
wire [11:0] imm;
wire [7:0] opcode;

assign opcode = instruction_reg[31:24];
assign rd = instruction_reg[23:20];
assign rs1 = instruction_reg[19:16];
assign rs2 = instruction_reg[15:12];
assign imm = instruction_reg[11:0];

// FSM Transistions
always@(posedge clk or negedge rst_n)
begin
   if(!rst_n)
      present_state <= RESET;
   else
      present_state <= next_state;
end


always@(*)
begin
  case(present_state)
  RESET: next_state = FETCH;
  FETCH: next_state = DECODE;
  DECODE:
  begin
    case(opcode)
    NOP: next_state = FETCH;
    LOAD,LOAD_IND,STORE,STORE_IND: next_state = MEMORY;
    HALT: next_state = HLT;
    default: next_state = EXECUTE;
    endcase
  end 
  EXECUTE: next_state = (opcode == MUL)? EXECUTE_WAIT : WRITEBACK;
  EXECUTE_WAIT: next_state = WRITEBACK;
  MEMORY:
  begin
      if(cpu_ready)
      begin
        case(opcode)
        LOAD,LOAD_IND: next_state = WRITEBACK;
        STORE,STORE_IND: next_state = FETCH;
        default: next_state = FETCH;
        endcase
      end
      else next_state = MEMORY;
  end 
  WRITEBACK: next_state = FETCH;
  HLT: next_state = HLT;
  default: next_state = RESET;
  endcase
end


//FETCH State 
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
      instruction_reg <= 0;
  else if(present_state == FETCH)
      instruction_reg <= instruction;
end

// ALU Operand Selection
always@(*)
begin
   op_a = R[rs1];
   case(opcode)
   ADD,SUB,MUL,OP_AND,OP_OR,CMP,EQ,OP_XOR,SLT,SLTU: op_b = R[rs2];
   OP_NOT: op_b = 0;
   ADDI,SUBI: op_b = { {DATA_WIDTH-12{imm[11]}},imm};
   SHL,SHR,SAR,ROL,ROR:op_b = { {DATA_WIDTH-5{1'b0}}, R[rs2][4:0]}; 
   ANDI,ORI,XORI: op_b = { {DATA_WIDTH-12{1'b0}},imm};
   default:
   begin
      op_b = 0;
   end
   endcase
end


// alu block
always@(*)
begin
  alu_res = 0;
  Z = 0;
  N = 0;
  C = 0;
  V = 0;
  case(opcode)
  ADD,ADDI:
  begin
    {C, alu_res[31:0]} = {1'b0, op_a} + {1'b0, op_b};
    Z = alu_res == 0;
    N = alu_res[31];
    V = ( ~(op_a[31] ^ op_b[31]) ) & (alu_res[31] ^ op_a[31]); 
  end
  SUB,SUBI,CMP:
  begin
    alu_res[31:0] = op_a - op_b;
    C = op_a >= op_b;
    Z = alu_res == 0;
    N = alu_res[31];
    V = ( (op_a[31] ^ op_b[31]) ) & (alu_res[31] ^ op_a[31]); 
  end
  MUL:
  begin
      alu_res[31:0] = op_a * op_b;
      Z = (alu_res[31:0] == 0);
      N = alu_res[31];
  end
  OP_AND,ANDI:
  begin
    alu_res[31:0] = op_a & op_b;
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  OP_OR,ORI:
  begin
    alu_res[31:0] = op_a | op_b;
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  OP_XOR,XORI:
  begin
    alu_res[31:0] = op_a ^ op_b;
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  OP_NOT:
  begin
    alu_res[31:0] = ~op_a;
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end


  SHL:
  begin
    alu_res[31:0] = op_a << op_b[4:0];
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  SHR:
  begin
    alu_res[31:0] = op_a >> op_b[4:0];
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  SAR:
  begin
    alu_res[31:0] = $signed(op_a) >>> op_b[4:0];
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end
  
  ROL:
  begin
      if(op_b[4:0] == 0)
        alu_res[31:0] = op_a;
      else
        alu_res[31:0] = (op_a << op_b[4:0]) | (op_a >> ( 32- op_b[4:0]));
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  ROR:
  begin
      if(op_b[4:0] == 0)
        alu_res[31:0] = op_a;
      else
        alu_res[31:0] = (op_a >> op_b[4:0]) | (op_a << ( 32- op_b[4:0]));

    Z = alu_res[31:0] == 0;
    N = alu_res[31];
  end

  EQ:
  begin
    alu_res[31:0] = (op_a == op_b) ? 1 : 0;
    
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
    C = 0;
    V = 0;
  end


  SLT:
  begin
    alu_res[31:0] = ( $signed(op_a) < $signed(op_b)) ? 1 : 0;
    
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
    C = 0;
    V = 0;
  end


  SLTU:
  begin
    alu_res[31:0] = ( op_a < op_b) ? 1 : 0;
    
    Z = alu_res[31:0] == 0;
    N = alu_res[31];
    C = 0;
    V = 0;
  end
  
  default:
  begin
    alu_res = 0;
    N = 0;
    C = 0;
    V = 0;
  end
  endcase
end

//Non ALU operations
always@(*)
begin
  case(opcode)
  LOAD_IMM:result_op = {{DATA_WIDTH-12{1'b0}},imm};
  MOV: result_op = R[rs1];
  LUI: result_op = {imm,20'b0};
  default: result_op = 0;
  endcase
end

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
    psr <= 0;
  else
  begin
    if(present_state == WRITEBACK)
    begin
      case(opcode)
       ADD,SUB,ADDI,SUBI,CMP:
       begin
        psr[0] <= Z;
        psr[1] <= N;
        psr[2] <= C;
        psr[3] <= V;
       end
       MUL,OP_AND,OP_OR,OP_NOT,OP_XOR,SHL,SHR,SAR,ROL,ROR,ANDI,ORI,XORI:
       begin
        psr[0] <= Z;
        psr[1] <= N;
       end

       EQ,SLT,SLTU:
       begin
        psr[0] <= Z;
       end
       
      default : psr <= psr;
      endcase
    end
  end
end

//PROGRAM COUNTER Operations
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
     pc <= 0;
  else
  begin
      if(present_state == DECODE)
      begin
         case(opcode)
         JMP: pc <= imm;
         JMP_IF: pc <= (R[rs1] !=0) ? imm : pc + 1; 
         BEQ: pc <= (psr[0]) ? imm : pc + 1; 
         BNE: pc <= (!psr[0]) ? imm : pc + 1; 
         BLT: pc <= (psr[1] ^ psr[3]) ? imm : pc + 1; 
         BGE: pc <= (!(psr[1] ^ psr[3])) ? imm : pc + 1; 
         BLTU: pc <= (!psr[2]) ? imm : pc + 1; 
         BGEU: pc <= (psr[2]) ? imm : pc + 1; 
         JMP_REG: pc <= R[rs1][PROG_ADDR_WIDTH-1:0];
         default: pc <=  pc + 1;         
         endcase
      end
  end   
end

//MEMORY State
always@(*)
begin
  cpu_req = 0;
  read_write = 0;
  addr = 0;
  wdata = 0;
  if(present_state == MEMORY)
  begin
      cpu_req = 1;
      case(opcode)
      LOAD:
      begin
          read_write = 0;
          addr = { {DATA_ADDR_WIDTH-12{1'b0}},imm};
      end
      LOAD_IND:
      begin
          read_write = 0;
          addr = R[rs1][DATA_ADDR_WIDTH-1:0];
      end
      STORE:
      begin
          read_write = 1;
          addr = { {DATA_ADDR_WIDTH-12{1'b0}},imm};
          wdata = R[rd];
      end
      STORE_IND:
      begin
          read_write = 1;
          addr = R[rs2][DATA_ADDR_WIDTH-1:0];
          wdata = R[rd];
      end
      endcase
  end
end

always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
    reg_rdata <= 0;
  else
    reg_rdata <= (present_state == MEMORY && cpu_ready) ? rdata : reg_rdata;
end

//WRITEBACK State
integer i;
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    for(i =0; i < 16 ; i = i+1)
        R[i] <= 0;
  end
  else if(present_state == WRITEBACK)
  begin
     case(opcode)
     ADD,SUB,MUL,OP_AND,OP_OR,OP_NOT,OP_XOR,SHL,SHR,SAR,ROL,ROR,EQ,SLT,SLTU,ADDI,SUBI,ANDI,ORI,XORI: R[rd] <= alu_res[31:0];
     LOAD_IMM,MOV,LUI: R[rd] <= result_op;
     LOAD,LOAD_IND: R[rd] <= reg_rdata;
     endcase
  end
end

endmodule
