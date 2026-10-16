import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import FoundationApp from "./FoundationApp";
import "./index.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {new URLSearchParams(window.location.search).has("foundation") ? <FoundationApp /> : <App />}
  </StrictMode>
);
