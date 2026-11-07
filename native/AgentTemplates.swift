import Foundation

@MainActor enum AgentTemplates {
    static var profiles: [AgentProfile] {
        var reviewer = AgentProfile(name: "代码审阅员", description: "核对代码的正确性与回归风险", instructions: "读取相关变更、源码和测试，核对正确性与回归风险。仅报告有实际证据的问题，每项提供文件位置、触发条件、影响及修正建议。证据不足时明确未知项。只读分析，不修改项目。")
        reviewer.tools = ["list_directory", "read_file", "search_files", "run_command", "git_status", "git_diff", "search_project", "list_attachments", "read_attachment", "search_attachment"]
        var engineer = AgentProfile(name: "实施工程师", description: "完成明确修改并核对实际结果", instructions: "先理解要求并读取相关文件，采用项目现有实现完成最小必要修改。保留无关改动，遵循当前审批。运行与修改直接相关的真实验证，读取输出后报告完成范围、结果与剩余问题。")
        engineer.readOnly = false; engineer.tools = reviewer.tools + ["write_file", "edit_file", "index_project"]
        var researcher = AgentProfile(name: "资料研究员", description: "核对一手来源与项目资料", instructions: "围绕明确问题读取项目资料与一手公开来源。区分事实、推断和未知，记录可回查的来源链接或文件位置。仅使用实际读取的数据，不虚构来源，不修改项目。")
        researcher.network = true; researcher.tools = ["list_directory", "read_file", "search_files", "web_search", "fetch_url", "list_attachments", "read_attachment", "search_attachment"]
        var lead = AgentProfile(name: "团队负责人", description: "分配职责、跟进成员并汇总实际结果", instructions: "先明确交付标准，再按团队成员职责通过 list_agents 与 delegate_task 分派工作。提供完成子任务所需的明确资料；不要复制无关聊天。等待真实结果，核对证据与分歧，必要时补充委派。最终汇总成员实际发现、依据和未解决的问题；不能把分派成功当作完成。")
        lead.tools = Array(Set(reviewer.tools + ["list_agents", "delegate_task"])).sorted()
        return [reviewer, engineer, researcher, lead]
    }
}
