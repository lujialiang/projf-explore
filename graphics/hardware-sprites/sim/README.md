# Simulations for Hardware Sprites

This folder contains Verilator simulations to accompany the Project F blog post: **[Hardware Sprites](https://projectf.io/posts/hardware-sprites/)**.

[Verilator](https://www.veripool.org/verilator/) creates C++ simulations of Verilog designs, while [SDL](https://www.libsdl.org) produces simple cross-platform graphics applications. By combining the two, you can simulate a hardware design on your PC: no dev board required! Verilator is fast, but it's still much slower than an FPGA. However, for these simple designs, you can reach 60 FPS on a modern PC.

If you're new to graphics simulations check out the blog post on [Verilog Simulation with Verilator and SDL](https://projectf.io/posts/verilog-sim-verilator-sdl/).

If you have a dev board, see the main [Hardware Sprites README](../README.md) for build instructions.

## Demos

* Tiny F - monochrome 8x8 pixel 'F' sprite
  * Inline - inline Verilog graphic
  * ROM - async ROM graphic
  * Scale - sprite scaling
  * Move - sprite moving
* Hourglass - 16-colour 8x8 pixel hourglass sprite
* Hedgehog - 16 colour hedgehog sprite

![](../../../doc/img/hardware-sprites.png?raw=true "")

_Hedgehog sprite video capture from Nexys Video._

## Build & Run

If this is the first time you've used Verilator and SDL, you need to [install dependencies](#installing-dependencies).

Make sure you're in the sim directory `projf-explore/graphics/hardware-sprites/sim`.

Build a specific simulation (hourglass, hedgehog etc.):

```shell
make hedgehog
```

Or build all simulations:

```shell
make all
```

Run the simulation executables from `obj_dir`:

```shell
./obj_dir/hedgehog
```

## Installing Dependencies

To build the simulations, you need:

1. C++ Toolchain
2. Verilator
3. SDL

The simulations should work on any modern platform, but I've confined my instructions to Linux and macOS. Windows installation depends on your choice of compiler, but the sims should work fine there too. For advice on SDL development on Windows, see [Lazy Foo' - Setting up SDL on Windows](https://lazyfoo.net/tutorials/SDL/01_hello_SDL/windows/index.php).

### Linux

For Debian and Ubuntu-based distros, you can use the following. Other distros will be similar.

Install a C++ toolchain via 'build-essential':

```shell
apt update
apt install build-essential
```

Install packages for Verilator and the dev version of SDL:

```shell
apt update
apt install verilator libsdl2-dev
```

That's it!

_If you want to build the latest version of Verilator yourself, see [Building Verilator for Linux](https://projectf.io/posts/building-ice40-fpga-toolchain/#verilator)._

### macOS

Install the [Homebrew](https://brew.sh/) package manager; this will also install Xcode Command Line Tools.

With Homebrew installed, you can run:

```shell
brew install verilator sdl2
```

And you're ready to go.
