#include "calculator.h"

#include <cassert>
#include <cstdio>

int main() {
  using namespace example;

  // Each assertion should kill at least one mutant that mull generates for
  // the operator/condition under test.
  assert(add(2, 3) == 5);
  assert(add(-1, 1) == 0);

  assert(multiply(4, 5) == 20);
  assert(multiply(0, 7) == 0);

  assert(max(2, 3) == 3);
  assert(max(9, 1) == 9);
  assert(max(5, 5) == 5);

  assert(is_positive(1));
  assert(!is_positive(0));
  assert(!is_positive(-1));

  std::puts("calculator_test: OK");
  return 0;
}
