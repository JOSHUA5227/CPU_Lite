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
output reg [PROG_ADDR_WIDTH-1:0] pc,

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

// Hazard Units Signals 
wire stall_en;
reg fetch_stall,decode_stall;
reg fetch_en,decode_en,exe_en,mem_en,wb_en;

reg hazard_decode_rs1_en,hazard_decode_rs2_en;
reg hazard_decode_rd_source;

reg [DATA_WIDTH-1:0] forward_exe_op_a,forward_exe_op_b;
reg forward_exe_a_en,forward_exe_b_en;

reg [DATA_WIDTH-1:0] forward_mem_op_a,forward_mem_op_b;
reg forward_mem_a_en,forward_mem_b_en;

reg [DATA_WIDTH-1:0] forward_wb_op_a,forward_wb_op_b;
reg forward_wb_a_en,forward_wb_b_en;

reg [DATA_WIDTH-1:0] forward_final_a,forward_final_b;

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
reg [PROG_ADDR_WIDTH-1:0] exe_pc,exe_out_pc;
reg [7:0] exe_opcode;
reg [3:0] exe_rs1,exe_rs2,exe_rd;
reg [11:0] exe_imm;

reg exe_read; // Read from R registers, when cache REQ = 1 read from cache
reg exe_write; // Write to R registers, when cache REQ = 1 write to cache
reg exe_cache_req; // Wether or not cache is needed
reg [3:0] exe_flags_write;
reg Z,N,C,V;
reg exe_branch_update;

reg [DATA_WIDTH-1:0] exe_op_a,exe_op_b;
reg [2*DATA_WIDTH-1:0] exe_alu_res;
reg [DATA_WIDTH-1:0] exe_result_op; // NON alu operations if needed
reg exe_valid;

// EXECUTE/MEMORY Registers
reg [PROG_ADDR_WIDTH-1:0] mem_pc;
reg [3:0] mem_rd;

reg [DATA_ADDR_WIDTH-1:0] mem_addr;
reg [DATA_WIDTH-1:0] mem_wdata;

reg mem_read;
reg mem_write;
reg mem_cache_req;

reg [DATA_WIDTH-1:0] mem_res;
reg mem_valid;

// MEMORY/WRITEBACK Registers
reg [PROG_ADDR_WIDTH-1:0] wb_pc;
reg [DATA_WIDTH-1:0] wb_res;
reg [3:0] wb_rd;

reg wb_write;
reg wb_cache_req;
reg wb_valid;

//Fetch Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    fetch_pc <= 0;
    fetch_instruct <= 0;
    fetch_valid <= 0;
  end
  else if(!stall_en && !fetch_stall)
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
  else if(!stall_en && !decode_stall)
  begin
    decode_pc <= fetch_pc;
    decode_instruct <= fetch_instruct;
    decode_valid <= (decode_en) ? fetch_valid : 0;
  end
end

always@(*)
begin
   decode_op_a = 0;
   decode_op_b = 0;
   if(decode_valid)
   begin
     case(decode_opcode)
     ADD,SUB,MUL,OP_AND,OP_OR,CMP,EQ,OP_XOR,SLT,SLTU:
     begin
       decode_op_a = R[decode_rs1];
       decode_op_b = R[decode_rs2]; 
     end
     OP_NOT,MOV,LOAD_IND,JMP_IF,JMP_REG:decode_op_a = R[decode_rs1];
     ADDI,SUBI:
     begin 
       decode_op_a = R[decode_rs1];
       decode_op_b = { {DATA_WIDTH-12{decode_imm[11]}},decode_imm};
     end
     SHL,SHR,SAR,OP_ROL,OP_ROR:
     begin
       decode_op_a = R[decode_rs1];
       decode_op_b = { {DATA_WIDTH-5{1'b0}}, R[decode_rs2][4:0]};
     end
     ANDI,ORI,XORI:
     begin 
       decode_op_a = R[decode_rs1];
       decode_op_b = { {DATA_WIDTH-12{1'b0}},decode_imm};
     end
     STORE: decode_op_a = R[decode_rd];
     STORE_IND:
     begin
       decode_op_a = R[decode_rd];
       decode_op_b = R[decode_rs2];
     end
     default:
     begin
        decode_op_a = 0;
        decode_op_b = 0;
     end
     endcase
   end
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
    
    psr <= 0;
    pc <= 0;
    exe_valid <= 0;
  end
  else if(!stall_en)
  begin
    exe_pc <= decode_pc;
    exe_opcode <= decode_opcode;
    exe_rs1 <= decode_rs1;
    exe_rs2 <= decode_rs2;
    exe_rd <= decode_rd;
    exe_imm <= decode_imm;
    
    exe_op_a <= forward_final_a; //comeback to
    exe_op_b <= forward_final_b; //comeback to
    
    psr[0] <= (exe_flags_write[0]) ? Z : psr[0]; 
    psr[1] <= (exe_flags_write[1]) ? N : psr[1]; 
    psr[2] <= (exe_flags_write[2]) ? C : psr[2]; 
    psr[3] <= (exe_flags_write[3]) ? V : psr[3]; 
  
    pc <= (exe_branch_update) ? exe_out_pc: pc + 1;
    exe_valid <= (exe_en) ? decode_valid : 0;
  end
end

always@(*)
begin
  exe_alu_res = 0;
  exe_flags_write = 0;
  Z = 0;
  N = 0;
  C = 0;
  V = 0;
  if(exe_valid)
  begin
    case(exe_opcode)
    ADD,ADDI:
    begin
      {C, exe_alu_res[31:0]} = {1'b0, exe_op_a} + {1'b0, exe_op_b};
      Z = exe_alu_res == 0;
      N = exe_alu_res[31];
      V = ( ~(exe_op_a[31] ^ exe_op_b[31]) ) & (exe_alu_res[31] ^ exe_op_a[31]); 
      exe_flags_write = 4'b1111;
    end
    SUB,SUBI,CMP:
    begin
      exe_alu_res[32:0] = exe_op_a - exe_op_b;
      C = exe_op_a >= exe_op_b;
      Z = exe_alu_res == 0;
      N = exe_alu_res[31];
      V = ( (exe_op_a[31] ^ exe_op_b[31]) ) & (exe_alu_res[31] ^ exe_op_a[31]); 
      exe_flags_write = 4'b1111;
    end
    MUL:
    begin
        exe_alu_res = exe_op_a * exe_op_b;
        Z = (exe_alu_res[31:0] == 0);
        N = exe_alu_res[31];
        exe_flags_write = 4'b0011;
    end
    OP_AND,ANDI:
    begin
      exe_alu_res[31:0] = exe_op_a & exe_op_b;
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    OP_OR,ORI:
    begin
      exe_alu_res[31:0] = exe_op_a | exe_op_b;
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    OP_XOR,XORI:
    begin
      exe_alu_res[31:0] = exe_op_a ^ exe_op_b;
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    OP_NOT:
    begin
      exe_alu_res[31:0] = ~exe_op_a;
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end


    SHL:
    begin
      exe_alu_res[31:0] = exe_op_a << exe_op_b[4:0];
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    SHR:
    begin
      exe_alu_res[31:0] = exe_op_a >> exe_op_b[4:0];
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    SAR:
    begin
      exe_alu_res[31:0] = $signed(exe_op_a) >>> exe_op_b[4:0];
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end
    
    OP_ROL:
    begin
        if(exe_op_b[4:0] == 0)
          exe_alu_res[31:0] = exe_op_a;
        else
          exe_alu_res[31:0] = (exe_op_a << exe_op_b[4:0]) | (exe_op_a >> ( 32- exe_op_b[4:0]));
      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    OP_ROR:
    begin
        if(exe_op_b[4:0] == 0)
          exe_alu_res[31:0] = exe_op_a;
        else
          exe_alu_res[31:0] = (exe_op_a >> exe_op_b[4:0]) | (exe_op_a << ( 32- exe_op_b[4:0]));

      Z = exe_alu_res[31:0] == 0;
      N = exe_alu_res[31];
      exe_flags_write = 4'b0011;
    end

    EQ:
    begin
      exe_alu_res[31:0] = (exe_op_a == exe_op_b) ? 1 : 0;
      
      Z = exe_alu_res[31:0] == 0;
      exe_flags_write = 4'b0001;
    end


    SLT:
    begin
      exe_alu_res[31:0] = ( $signed(exe_op_a) < $signed(exe_op_b)) ? 1 : 0;
      
      Z = exe_alu_res[31:0] == 0;
      exe_flags_write = 4'b0001;
    end


    SLTU:
    begin
      exe_alu_res[31:0] = ( exe_op_a < exe_op_b) ? 1 : 0;
      
      Z = exe_alu_res[31:0] == 0;
      exe_flags_write = 4'b0001;
    end
    
    default:
    begin
      exe_alu_res = 0;
      N = 0;
      C = 0;
      V = 0;
      exe_flags_write = 4'b0000;
    end
    endcase
  end
end

//Non ALU operations
always@(*)
begin
  exe_result_op = 0;
  if(exe_valid)
  begin
    case(exe_opcode)
    LOAD_IMM:exe_result_op = {{DATA_WIDTH-12{1'b0}},exe_imm};
    MOV: exe_result_op = exe_op_a;
    LUI: exe_result_op = {exe_imm,20'b0};
    default: exe_result_op = 0;
    endcase
  end
end

//Branch Operations
always@(*)
begin
  exe_out_pc = exe_pc;
  exe_branch_update = 0;
  if(exe_valid)
  begin
    case(exe_opcode)
       JMP:
       begin
       exe_out_pc = exe_imm;
       exe_branch_update = 1;
       end
       JMP_IF:
       begin
         if(exe_op_a != 0)
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BEQ:
       begin
         if(psr[0])
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BNE: 
       begin
         if(!psr[0])
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BLT: 
       begin
         if(psr[1] ^ psr[3])
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BGE:
       begin
         if(!(psr[1] ^ psr[3]))
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BLTU:
       begin
         if(!psr[2])
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       BGEU:
       begin
         if(psr[2])
         begin
           exe_out_pc = exe_imm;
           exe_branch_update = 1;  
         end
       end
       JMP_REG:
       begin
           exe_out_pc = exe_op_a[PROG_ADDR_WIDTH-1:0];
           exe_branch_update = 1;  
       end
       default:
       begin
        exe_out_pc =  exe_pc; 
        exe_branch_update = 0;
       end
    endcase
  end
end

//FLUSHING
always@(*)
begin
  if(exe_branch_update)
  begin
    fetch_en = 0;
    decode_en = 0;
  end
  else
  begin
    fetch_en = 1;
    decode_en = 1;
  end
end


//Read Write Enabling
always@(*)
begin
  exe_read = 0;
  exe_write = 0;
  exe_cache_req = 0;
  if(exe_valid)
  begin
    case(exe_opcode)
    ADD,SUB,MUL,OP_AND,OP_OR,OP_XOR,OP_NOT,EQ,SHL,SHR,SAR,OP_ROL,OP_ROR,ADDI,SUBI,ANDI,ORI,XORI,SLT,SLTU,MOV:
    begin
      exe_read = 1;
      exe_write = 1;
      exe_cache_req = 0;
    end 
    LOAD_IMM,LUI:
    begin
      exe_read = 0;
      exe_write = 1;
      exe_cache_req = 0;
    end
    LOAD,LOAD_IND:
    begin
      exe_read = 1;
      exe_write = 0;
      exe_cache_req = 1;
    end
    STORE,STORE_IND:
    begin
      exe_read = 0;
      exe_write = 1;
      exe_cache_req = 1;
    end
    default:
    begin
      exe_read = 0;
      exe_write = 0;
      exe_cache_req = 0;
    end 
    endcase
  end
end

//Memory Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    mem_pc <= 0;
    mem_rd <= 0; 

    mem_addr <= 0; 
    mem_wdata <= 0;

    mem_read <= 0;
    mem_write <= 0;
    mem_cache_req <= 0;

    mem_res <= 0;
    mem_valid <= 0;
  end
  else if(!stall_en)
  begin
    mem_pc <= exe_out_pc;
    mem_rd <= exe_rd; 
  
    case(exe_opcode)
    LOAD,STORE: mem_addr <= { {DATA_ADDR_WIDTH-12{1'b0}},exe_imm};
    LOAD_IND: mem_addr <= exe_op_a[DATA_ADDR_WIDTH-1:0];
    STORE_IND: mem_addr <= exe_op_b[DATA_ADDR_WIDTH-1:0];
    default: mem_addr <= 0;
    endcase

    case(exe_opcode)
    STORE,STORE_IND: mem_wdata <= exe_op_a; 
    default: mem_wdata <= 0;
    endcase

    mem_read <= exe_read;
    mem_write <= exe_write;
    mem_cache_req <= exe_cache_req;

    case(exe_opcode)
    ADD,SUB,MUL,OP_AND,OP_OR,OP_XOR,OP_NOT,EQ,SHL,SHR,SAR,OP_ROL,OP_ROR,ADDI,SUBI,ANDI,ORI,XORI,SLT,SLTU : mem_res <= exe_alu_res[DATA_WIDTH-1:0];  
    LOAD_IMM,LUI,MOV: mem_res <= exe_result_op;
    LOAD,LOAD_IND: mem_res <= rdata;
    default: mem_res <= 0;
    endcase
  
    mem_valid <= exe_valid;
  end
end

always@(*)
begin
  cpu_req = 0;
  read_write = 0;
  addr = 0;
  wdata = 0;
  
  if(mem_cache_req && mem_valid)
  begin
    cpu_req = 1;
    read_write = mem_write;
    addr = mem_addr;
    wdata = mem_wdata;
  end
end

assign stall_en = mem_cache_req && !cpu_ready;

//WriteBack Pipeline
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    wb_pc <= 0;
    wb_res <= 0;
    wb_rd <= 0;

    wb_write <= 0;
    wb_cache_req <= 0;
    wb_valid <= 0;
  end
  else if(!stall_en)
  begin
    wb_pc <= mem_pc;
    wb_rd <= mem_rd;
    
    wb_write <= mem_write;
    wb_cache_req <= mem_cache_req;
    wb_res <= mem_res;

    wb_valid <= mem_valid;
  end
end

integer i;
always@(posedge clk or negedge rst_n)
begin
  if(!rst_n)
  begin
    for(i = 0; i < 16 ; i = i + 1)
        R[i] <= 0;
  end
  else if(!stall_en && wb_valid)
  begin
      if(wb_write && !wb_cache_req)
         R[wb_rd] <= wb_res;
      else if(!wb_write && wb_cache_req)
         R[wb_rd] <= wb_res;
  end
end

// HAZARD UNIT

always@(*)
begin
  hazard_decode_rs1_en = 0;
  hazard_decode_rs2_en = 0;
  hazard_decode_rd_source = 0;

  if(decode_valid)
  begin
    case(decode_opcode)
    ADD,SUB,MUL,OP_AND,OP_OR,CMP,EQ,OP_XOR,SLT,SLTU,SHL,SHR,SAR,OP_ROL,OP_ROR:
    begin
      hazard_decode_rs1_en = 1;
      hazard_decode_rs2_en = 1;
    end 
    OP_NOT,MOV,LOAD_IND,JMP_IF,JMP_REG,ADDI,SUBI,ANDI,ORI,XORI:
    begin
      hazard_decode_rs1_en = 1;
    end 
    STORE:
    begin
      hazard_decode_rd_source = 1;
    end
    STORE_IND:
    begin
      hazard_decode_rd_source = 1;
      hazard_decode_rs2_en =1;
    end
    default:
    begin
      hazard_decode_rs1_en = 0;
      hazard_decode_rs2_en = 0;
      hazard_decode_rd_source = 0;
    end
    endcase
  end

end

wire exe_hazard_R_dependency;
assign exe_hazard_R_dependency = (!exe_write && exe_cache_req) || (exe_write && !exe_cache_req) ;

wire hazard_exe_rs1;
assign hazard_exe_rs1 = hazard_decode_rs1_en && (exe_rd == decode_rs1);

wire hazard_exe_rs2;
assign hazard_exe_rs2 = hazard_decode_rs2_en && (exe_rd == decode_rs2);

wire hazard_exe_rd;
assign hazard_exe_rd = hazard_decode_rd_source && (exe_rd == decode_rd);

wire hazard_exe_any;
assign hazard_exe_any = hazard_exe_rs1 || hazard_exe_rs2 || hazard_exe_rd;


wire mem_hazard_R_dependency;
assign mem_hazard_R_dependency = (!mem_write && mem_cache_req) || (mem_write && !mem_cache_req) ;

wire hazard_mem_rs1;
assign hazard_mem_rs1 = hazard_decode_rs1_en && (mem_rd == decode_rs1);

wire hazard_mem_rs2;
assign hazard_mem_rs2 = hazard_decode_rs2_en && (mem_rd == decode_rs2);

wire hazard_mem_rd;
assign hazard_mem_rd = hazard_decode_rd_source && (mem_rd == decode_rd);


wire wb_hazard_R_dependency;
assign wb_hazard_R_dependency = (!wb_write && wb_cache_req) || (wb_write && !wb_cache_req) ;

wire hazard_wb_rs1;
assign hazard_wb_rs1 = hazard_decode_rs1_en && (wb_rd == decode_rs1);

wire hazard_wb_rs2;
assign hazard_wb_rs2 = hazard_decode_rs2_en && (wb_rd == decode_rs2);

wire hazard_wb_rd;
assign hazard_wb_rd = hazard_decode_rd_source && (wb_rd == decode_rd);
//FORWARDING UNIT
always@(*)
begin
  forward_exe_op_a = 0;
  forward_exe_op_b = 0;
  forward_exe_a_en = 0;
  forward_exe_b_en = 0;

  forward_mem_op_a = 0;
  forward_mem_op_b = 0;
  forward_mem_a_en = 0;
  forward_mem_b_en = 0;

  forward_wb_op_a = 0;
  forward_wb_op_b = 0;
  forward_wb_a_en = 0;
  forward_wb_b_en = 0;

  exe_en = 1;
  fetch_stall = 0;
  decode_stall = 0;

// EXECUTE bubbling for Load hazards
  if(decode_valid && exe_valid && exe_hazard_R_dependency && hazard_exe_any) 
  begin
    case(exe_opcode)
    LOAD,LOAD_IND:
    begin
      exe_en = 0;
      fetch_stall = 1;
      decode_stall = 1;
    end
    default:
    begin
      exe_en = 1;
      fetch_stall = 0;
      decode_stall = 0;
    end
    endcase
  end

// EXECUTE forwarding
  if(decode_valid && exe_valid && exe_hazard_R_dependency && (hazard_exe_rs1 || hazard_exe_rd)) 
  begin
    case(exe_opcode)
    ADD,SUB,MUL,OP_AND,OP_OR,OP_XOR,OP_NOT,EQ,SHL,SHR,SAR,OP_ROL,OP_ROR,ADDI,SUBI,ANDI,ORI,XORI,SLT,SLTU :
    begin
      forward_exe_a_en = 1;
      forward_exe_op_a = exe_alu_res[DATA_WIDTH-1:0];  
    end
    LOAD_IMM,LUI,MOV: 
    begin
      forward_exe_a_en = 1;
      forward_exe_op_a = exe_result_op;
    end
    default: 
    begin
      forward_exe_a_en = 0;
      forward_exe_op_a = 0;
    end
    endcase
  end

  if(decode_valid && exe_valid && exe_hazard_R_dependency && hazard_exe_rs2)
  begin
    case(exe_opcode)
    ADD,SUB,MUL,OP_AND,OP_OR,OP_XOR,OP_NOT,EQ,SHL,SHR,SAR,OP_ROL,OP_ROR,ADDI,SUBI,ANDI,ORI,XORI,SLT,SLTU : 
    begin
      forward_exe_b_en = 1;
      forward_exe_op_b = exe_alu_res[DATA_WIDTH-1:0];  
    end
    LOAD_IMM,LUI,MOV: 
    begin
    forward_exe_b_en = 1;
    forward_exe_op_b = exe_result_op;
    end
    default: 
    begin
      forward_exe_b_en = 0;
      forward_exe_op_b = 0;
    end 
    endcase
  end

// MEM forwarding
  if(decode_valid && mem_valid && mem_hazard_R_dependency && (hazard_mem_rs1 || hazard_mem_rd)) 
  begin
    forward_mem_op_a = mem_res;
    forward_mem_a_en = 1;
  end

  if(decode_valid && mem_valid && mem_hazard_R_dependency && hazard_mem_rs2)
  begin
    forward_mem_op_b = mem_res;
    forward_mem_b_en = 1;
  end

//WRITEBACK forwarding
  if(decode_valid && wb_valid && wb_hazard_R_dependency && (hazard_wb_rs1 || hazard_wb_rd)) 
  begin
    forward_wb_op_a = wb_res;
    forward_wb_a_en = 1;
  end

  if(decode_valid && wb_valid && wb_hazard_R_dependency && hazard_wb_rs2)
  begin
    forward_wb_op_b = wb_res;
    forward_wb_b_en = 1;
  end
end

always@(*)
begin
  if(forward_exe_a_en)
      forward_final_a = forward_exe_op_a;
  else if(forward_mem_a_en)
      forward_final_a = forward_mem_op_a;
  else if(forward_wb_a_en)
      forward_final_a = forward_wb_op_a;
  else
      forward_final_a = decode_op_a;
end

always@(*)
begin
  if(forward_exe_b_en)
      forward_final_b = forward_exe_op_b;
  else if(forward_mem_b_en)
      forward_final_b = forward_mem_op_b;
  else if(forward_wb_b_en)
      forward_final_b = forward_wb_op_b;
  else
      forward_final_b = decode_op_b;
end
endmodule
