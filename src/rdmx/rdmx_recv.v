//===================================================================================================
//                            ------->  Revision History  <------
//===================================================================================================
//
//   Date     Who   Ver  Changes
//===================================================================================================
// 30-Oct-23  DWW     1  Initial creation
//
// 12-Jan-24  DWW  1001  Changed name to RDMX
//===================================================================================================

/*

    This module receives RDMX packets on an AXI-Stream bus and performs the relevant AXI write
    transactions.

    And RDMX packet consists of a header that is one data-cycle wide (i.e., 64 bytes) followed
    by the data-cycles that comprise the outgoing W-channel on the M_AXI bus.

    The RDMX header contains the AXI target-address and burst-length of the write transaction.

*/

module rdmx_recv #
(
    parameter DATA_WBITS        = 512,
    parameter DATA_WBYTS        = (DATA_WBITS / 8),
    parameter ADDR_WBITS        = 64
)
(
    input wire  clk, resetn,

    // Keeps a count of the total number of packets received
    output reg[63:0] packets_rcvd,

    //==========================================================================
    //                     AXI Stream for incoming RDMX packets
    //==========================================================================
    input[DATA_WBITS-1:0] AXIS_RDMX_TDATA,
    input[DATA_WBYTS-1:0] AXIS_RDMX_TKEEP,
    input                 AXIS_RDMX_TVALID,
    input                 AXIS_RDMX_TLAST,
    output                AXIS_RDMX_TREADY,
    //==========================================================================



    //=================  This is the main AXI4-master interface  ================

    // "Specify write address"              -- Master --    -- Slave --
    output[ADDR_WBITS-1:0]                   M_AXI_AWADDR,
    output                                   M_AXI_AWVALID,
    output[7:0]                              M_AXI_AWLEN,
    output[2:0]                              M_AXI_AWSIZE,
    output[3:0]                              M_AXI_AWID,
    output[1:0]                              M_AXI_AWBURST,
    output                                   M_AXI_AWLOCK,
    output[3:0]                              M_AXI_AWCACHE,
    output[3:0]                              M_AXI_AWQOS,
    output[2:0]                              M_AXI_AWPROT,

    input                                                   M_AXI_AWREADY,

    // "Write Data"                         -- Master --    -- Slave --
    output[DATA_WBITS-1:0]                  M_AXI_WDATA,
    output[DATA_WBYTS-1:0]                  M_AXI_WSTRB,
    output                                  M_AXI_WVALID,
    output                                  M_AXI_WLAST,
    input                                                   M_AXI_WREADY,

    // "Send Write Response"                -- Master --    -- Slave --
    input[1:0]                                              M_AXI_BRESP,
    input                                                   M_AXI_BVALID,
    output                                  M_AXI_BREADY,

    // "Specify read address"               -- Master --    -- Slave --
    output[ADDR_WBITS-1:0]                  M_AXI_ARADDR,
    output                                  M_AXI_ARVALID,
    output[2:0]                             M_AXI_ARPROT,
    output                                  M_AXI_ARLOCK,
    output[3:0]                             M_AXI_ARID,
    output[7:0]                             M_AXI_ARLEN,
    output[1:0]                             M_AXI_ARBURST,
    output[3:0]                             M_AXI_ARCACHE,
    output[3:0]                             M_AXI_ARQOS,
    input                                                   M_AXI_ARREADY,

    // "Read data back to master"           -- Master --    -- Slave --
    input[DATA_WBITS-1:0]                                   M_AXI_RDATA,
    input                                                   M_AXI_RVALID,
    input[1:0]                                              M_AXI_RRESP,
    input                                                   M_AXI_RLAST,
    output                                  M_AXI_RREADY
    //==========================================================================


);

// 8 bytes of address, plus one AWLEN byte
localparam RDMX_HDR_BYTES = 9; 

// This specifies how many entries can be stored in the FIFOS that
// buffer our incoming AXI write requests
localparam PACKET_FIFO_DEPTH = 1024;

// The state of the input state-machine
reg[1:0] ism_state;

// These are the possible states of ism_state
localparam ISM_STARTING     = 0;
localparam ISM_WAIT_FOR_HDR = 1;
localparam ISM_XFER_PACKET  = 2;

// We're always ready to receive an AXI "write acknowledgement"
assign M_AXI_BREADY = 1;

// Set up constant fields in the AW channel
assign M_AXI_AWID    = 0;
assign M_AXI_AWSIZE  = $clog2(DATA_WBYTS);
assign M_AXI_AWBURST = 1;       /* Burst type = Increment */
assign M_AXI_AWLOCK  = 0;       /* Not locked             */
assign M_AXI_AWCACHE = 0;       /* No caching             */
assign M_AXI_AWPROT  = 1;       /* Privileged Access      */
assign M_AXI_AWQOS   = 0;       /* No QoS                 */


// AXIS_RDMX_TDATA comes to us in little-endian order.  Create a byte-swapped version of it
// so we can easily break out the fields of the header in big-endian
wire[DATA_WBITS-1:0] AXIS_RDMX_TDATA_swapped;
genvar i;
for (i=0; i<DATA_WBYTS; i=i+1) begin
    assign AXIS_RDMX_TDATA_swapped[i*8 +:8] = AXIS_RDMX_TDATA[(DATA_WBYTS-1-i)*8 +:8];
end 

// These are the fields that comprise an RDMX packet header
wire[ 6 *8-1:0] eth_dst_mac, eth_src_mac;
wire[ 2 *8-1:0] eth_frame_type;
wire[ 2 *8-1:0] ip4_ver_dsf, ip4_length, ip4_id, ip4_flags, ip4_ttl_prot, ip4_checksum;
wire[ 2 *8-1:0] ip4_srcip_h, ip4_srcip_l, ip4_dstip_h, ip4_dstip_l;
wire[ 2 *8-1:0] udp_src_port, udp_dst_port, udp_length, udp_checksum;
wire[ 2 *8-1:0] rdmx_magic;
wire[ 8 *8-1:0] rdmx_target_addr;
wire[12 *8-1:0] rdmx_reserved;

// The "upd_length" field includes 8 bytes for the UDP header
localparam UDP_HDR_LEN  = 8;

// 22 bytes of the UDP packet data in an RDMX packet are RDMX header bytes
localparam RDMX_HDR_LEN = 22;

// This is the 64-byte packet header for an RDMX packet.  This is an ordinary UDP packet
// with 22 bytes of RDMX header fields appended
assign
{

    // Ethernet header fields - 14 bytes
    eth_dst_mac,
    eth_src_mac,
    eth_frame_type,

    // IPv4 header fields - 20 bytes
    ip4_ver_dsf,
    ip4_length,
    ip4_id,
    ip4_flags,
    ip4_ttl_prot,
    ip4_checksum,
    ip4_srcip_h,
    ip4_srcip_l,
    ip4_dstip_h,
    ip4_dstip_l,

    // UDP header fields - 8 bytes
    udp_src_port,
    udp_dst_port,
    udp_length,
    udp_checksum,
    
    // RDMX header fields - 22 bytes
    rdmx_magic,
    rdmx_target_addr,
    rdmx_reserved

} = AXIS_RDMX_TDATA_swapped;


// We will write an entry to the target-address FIFO when:
//     (1) We're waiting for an incoming RDMX packet header 
// and (2) We have a valid data-cycle incoming on the AXIS_RDMX bus 
wire ftain_tvalid = (ism_state == ISM_WAIT_FOR_HDR) & AXIS_RDMX_TREADY & AXIS_RDMX_TVALID;   
wire ftain_tready;


// We will write an entry to the packet-data FIFO when:
//     (1) We're waiting for an incoming RDMX packet data
// and (2) We have a valid data-cycle incoming on the AXIS_RDMX bus 
wire fpdin_tvalid = (ism_state == ISM_XFER_PACKET) & AXIS_RDMX_TREADY & AXIS_RDMX_TVALID;
wire fpdin_tready;

// We're ready to receive on the AXIS_RDMX interface:
//  (1) When waiting for a packet header, we're ready when the address FIFO is ready
//  (2) When waiting for packet data, we're ready when the data FIFO is ready
assign AXIS_RDMX_TREADY = (ism_state == ISM_WAIT_FOR_HDR) ? ftain_tready 
                        : (ism_state == ISM_XFER_PACKET ) ? fpdin_tready
                        : 0;


//====================================================================================
// This block computes the AXI AWLEN value for the packet by examining the
// "udp_length" field of the RDMX header.
//
//  The "awlen" value output by this block is valid only when:
//      ism_state = ISM_WAIT_FOR_HDR
//              -and-
//      AXIS_RDMX_TVALID is high.
//
//====================================================================================
wire[15:0] data_bytes_in_packet = udp_length - UDP_HDR_LEN - RDMX_HDR_LEN;
wire[ 7:0] dbip_div_64          = (data_bytes_in_packet >> 6);
wire       dbip_has_remainder   = (data_bytes_in_packet & 6'b111111) ? 1 : 0;
wire[7:0]  awlen                = (dbip_div_64 + dbip_has_remainder - 1);
//====================================================================================



//====================================================================================
// The input state-machine: reads incoming RDMX packets and stuffs the target address
// from the header into the target-address FIFO and stuffs the remainder of the packet
// into the packet-data FIFO.
//====================================================================================
always @(posedge clk) begin
    if (resetn == 0) begin
        ism_state <= ISM_STARTING;

    end else case (ism_state)

        // Here we're just coming out of reset
        ISM_STARTING: 
            begin
                ism_state <= ISM_WAIT_FOR_HDR;
            end

        // Wait for an RDMX packet header to arrive
        ISM_WAIT_FOR_HDR:
            if (AXIS_RDMX_TREADY & AXIS_RDMX_TVALID) begin
                ism_state <= ISM_XFER_PACKET;
            end

        // Here, we're reading in data-beats from the stream and writing them to packet-data FIFO
        ISM_XFER_PACKET:
            if (AXIS_RDMX_TREADY & AXIS_RDMX_TVALID & AXIS_RDMX_TLAST) begin
                ism_state <= ISM_WAIT_FOR_HDR;
            end

    endcase
end
//====================================================================================


//====================================================================================
// This block keeps a count of the total number of packet received
//====================================================================================
always @(posedge clk) begin
    if (resetn == 0)
        packets_rcvd <= 0;
    else if (AXIS_RDMX_TVALID & AXIS_RDMX_TREADY & AXIS_RDMX_TLAST)
        packets_rcvd <= packets_rcvd + 1;
end
//====================================================================================



//====================================================================================
// This FIFO holds the incoming packet data
//====================================================================================
xpm_fifo_axis #
(
   .FIFO_DEPTH(PACKET_FIFO_DEPTH), // DECIMAL
   .TDATA_WIDTH(DATA_WBITS),       // DECIMAL
   .FIFO_MEMORY_TYPE("auto"),      // String
   .PACKET_FIFO("false"),          // String
   .USE_ADV_FEATURES("0000")       // String
)
packet_data_fifo
(
    // Clock and reset
   .s_aclk   (clk   ),                       
   .m_aclk   (clk   ),             
   .s_aresetn(resetn),

    // The input of this FIFO is the AXIS_RDMX interface
   .s_axis_tdata (AXIS_RDMX_TDATA),
   .s_axis_tkeep (AXIS_RDMX_TKEEP),
   .s_axis_tlast (AXIS_RDMX_TLAST),
   .s_axis_tvalid(fpdin_tvalid   ),
   .s_axis_tready(fpdin_tready   ),

    // The output of this FIFO drives the "W" channel of the M_AXI interface
   .m_axis_tdata (M_AXI_WDATA  ),     
   .m_axis_tkeep (M_AXI_WSTRB  ),
   .m_axis_tvalid(M_AXI_WVALID ),       
   .m_axis_tlast (M_AXI_WLAST  ),         
   .m_axis_tready(M_AXI_WREADY ),

    // Unused input stream signals
   .s_axis_tdest(),
   .s_axis_tid  (),
   .s_axis_tstrb(),
   .s_axis_tuser(),

    // Unused output stream signals
   .m_axis_tdest(),             
   .m_axis_tid  (),               
   .m_axis_tstrb(), 
   .m_axis_tuser(),         

    // Other unused signals
   .almost_empty_axis(),
   .almost_full_axis(), 
   .dbiterr_axis(),          
   .prog_empty_axis(), 
   .prog_full_axis(), 
   .rd_data_count_axis(), 
   .sbiterr_axis(),
   .wr_data_count_axis(),
   .injectdbiterr_axis(),
   .injectsbiterr_axis()
);
//====================================================================================




//====================================================================================
// This FIFO holds the target-address of the incoming data packets
//====================================================================================
xpm_fifo_axis #
(
   .FIFO_DEPTH(PACKET_FIFO_DEPTH),  // DECIMAL
   .TDATA_WIDTH(RDMX_HDR_BYTES*8),  // DECIMAL
   .FIFO_MEMORY_TYPE("auto"),       // String
   .PACKET_FIFO("false"),           // String
   .USE_ADV_FEATURES("0000")        // String
)
target_addr_fifo
(
    // Clock and reset
   .s_aclk   (clk   ),                       
   .m_aclk   (clk   ),             
   .s_aresetn(resetn),

    // The input to this FIFO is derived from packet-headers on AXIS_RDMX
   .s_axis_tdata ({awlen, rdmx_target_addr}),
   .s_axis_tvalid(ftain_tvalid        ),
   .s_axis_tready(ftain_tready        ),

    // The output bus of the FIFO drives the AW-channel of the M_AXI interface
   .m_axis_tdata ({M_AXI_AWLEN, M_AXI_AWADDR}),     
   .m_axis_tvalid(M_AXI_AWVALID              ),       
   .m_axis_tready(M_AXI_AWREADY              ),     

    // Unused input stream signals
   .s_axis_tdest(),
   .s_axis_tid  (),
   .s_axis_tstrb(),
   .s_axis_tuser(),
   .s_axis_tkeep(),
   .s_axis_tlast(),

    // Unused output stream signals
   .m_axis_tdest(),             
   .m_axis_tid  (),               
   .m_axis_tstrb(), 
   .m_axis_tuser(),         
   .m_axis_tkeep(),           
   .m_axis_tlast(),         

    // Other unused signals
   .almost_empty_axis(),
   .almost_full_axis(), 
   .dbiterr_axis(),          
   .prog_empty_axis(), 
   .prog_full_axis(), 
   .rd_data_count_axis(), 
   .sbiterr_axis(),
   .wr_data_count_axis(),
   .injectdbiterr_axis(),
   .injectsbiterr_axis()
);
//====================================================================================

endmodule