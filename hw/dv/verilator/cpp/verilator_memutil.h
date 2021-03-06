// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef OPENTITAN_HW_DV_VERILATOR_CPP_VERILATOR_MEMUTIL_H_
#define OPENTITAN_HW_DV_VERILATOR_CPP_VERILATOR_MEMUTIL_H_

#include <map>
#include <string>
#include <vltstd/svdpi.h>

#include "sim_ctrl_extension.h"

enum MemImageType {
  kMemImageUnknown = 0,
  kMemImageElf,
  kMemImageVmem,
};

// The "load" location of a memory area. base is the lowest address in
// the area, and should correspond to an ELF file's LMA. size is the
// length of the area in bytes.
struct MemAreaLoc {
  uint32_t base;
  uint32_t size;
};

struct MemArea {
  std::string name;      // Unique identifier
  std::string location;  // Design scope location
  uint32_t width_byte;   // Memory width in bytes
  MemAreaLoc addr_loc;   // Address location. If !size, location is unknown.
};

/**
 * Provide various memory loading utilities for Verilator simulations
 *
 * These utilities require the corresponding DPI functions:
 * simutil_verilator_memload()
 * simutil_verilator_set_mem()
 * to be defined somewhere as SystemVerilog functions.
 */
class VerilatorMemUtil : public SimCtrlExtension {
 public:
  /**
   * Register a memory as instantiated by generic ram
   *
   * The |name| must be a unique identifier. The function will return false
   * if |name| is already used. |location| is the path to the scope of the
   * instantiated memory, which needs to support the DPI-C interfaces
   * 'simutil_verilator_memload' and 'simutil_verilator_set_mem' used for
   * 'vmem' and 'elf' files, respectively.
   * The |width_bit| argument specifies the with in bits of the target memory
   * instance (used for packing data). This must be a multiple of 8.
   * If |addr_loc| is not null, it gives the base and size of the
   * memory for loading in the address space (corresponding to LMAs in
   * an ELF file).
   *
   * Memories must be registered before command arguments are parsed by
   * ParseCommandArgs() in order for them to be known.
   */
  bool RegisterMemoryArea(const std::string name, const std::string location,
                          size_t width_bit, const MemAreaLoc *addr_loc);

  /**
   * Register a memory with default width (32bits)
   */
  bool RegisterMemoryArea(const std::string name, const std::string location);

  /**
   * Parse command line arguments
   *
   * Process all recognized command-line arguments from argc/argv.
   *
   * @param argc, argv Standard C command line arguments
   * @param exit_app Indicate that program should terminate
   * @return Return code, true == success
   */
  bool ParseCLIArguments(int argc, char **argv, bool &exit_app) override;

 private:
  std::map<std::string, MemArea> name_to_mem_;
  std::map<uint32_t, const MemArea *> addr_to_mem_;

  /**
   * Print a list of all registered memory regions
   *
   * @see RegisterMemoryArea()
   */
  void PrintMemRegions() const;

  /**
   * Load the file at filepath into the named memory. If type is
   * kMemImageUnknown, the file type is determined from the path.
   */
  void LoadFileToNamedMem(bool verbose, const std::string &name,
                          const std::string &filepath, MemImageType type);
  /**
   * Load an ELF file, placing segments in memories by LMA
   */
  void LoadElfToMemories(bool verbose, const std::string &filepath);

  /**
   * Try to find a region for the given LMA. Returns nullptr if none is found.
   */
  const MemArea *FindRegionForAddr(uint32_t lma) const;
};

#endif  // OPENTITAN_HW_DV_VERILATOR_CPP_VERILATOR_MEMUTIL_H_
