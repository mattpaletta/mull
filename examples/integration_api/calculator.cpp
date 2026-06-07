#include "calculator.h"

namespace example {

int add(int a, int b) {
  return a + b;
}

int multiply(int a, int b) {
  return a * b;
}

int max(int a, int b) {
  return a > b ? a : b;
}

bool is_positive(int x) {
  return x > 0;
}

} // namespace example
