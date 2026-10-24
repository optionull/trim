function total(values: number[]): number {
  return values.reduce((a, b) => a + b, 0);
}

const wrong: number = "three";
console.log(total([1, 2, 3]), wrong);
