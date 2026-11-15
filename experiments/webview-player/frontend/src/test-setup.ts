import "@testing-library/jest-dom/vitest";

Object.defineProperty(HTMLCanvasElement.prototype, "getContext", {
  value: () => ({ setTransform() {}, clearRect() {}, fillRect() {}, fillStyle: "" }),
});
