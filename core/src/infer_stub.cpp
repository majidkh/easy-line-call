// Non-Apple inference stub: no ANE here, callers use their own backend.
#include "tennis/infer.hpp"

namespace tennis {

std::unique_ptr<BallDetector> CreateDetector(const std::string&,
                                             const std::string&,
                                             const std::string&,
                                             std::string& err) {
  err = "in-core inference needs an Apple build (Core ML)";
  return nullptr;
}

}  // namespace tennis
