// Tang Nano 9K HDMI timing
// Gowin SDC parser: keep each create_* on one line (no '\' continuations).

// Board crystal: 27 MHz → period 37.037 ns
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]

// rPLL CLKOUT: 27 * 14 / 3 = 126 MHz (5x TMDS / OSER10 FCLK)
create_generated_clock -name clk_5x -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 14 -divide_by 3 [get_pins {u_pll/rpll_inst/CLKOUT}]

// CLKDIV ÷5: 126 / 5 = 25.2 MHz (pixel clock)
create_generated_clock -name pixclk -source [get_pins {u_pll/rpll_inst/CLKOUT}] -master_clock clk_5x -divide_by 5 [get_pins {u_div5/clkdiv_inst/CLKOUT}]
