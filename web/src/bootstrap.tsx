if (import.meta.env.MODE === "futures") {
  document.title = "研序 · 期货研究";
  void import("./futures");
} else {
  document.title = "Agent OS · 管理工作台";
  void import("./console");
}
