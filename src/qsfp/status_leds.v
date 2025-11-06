module status_leds
(
    input qsfp0_up, qsfp1_up, pcie_up,

    output[3:0] led_green_l
);

assign led_green_l  = {pcie_up, 1'b0, qsfp1_up, qsfp0_up};

endmodule