import SwiftUI

/// 登录页
///
/// iPod 没有键盘，所以这里不用转盘界面，改为常规表单 + iPod 配色。
/// 连接方式二选一：FNID（自动探测最佳链路）或手动填写服务器地址。
struct LoginView: View {
    @Environment(Session.self) private var session

    /// 输入框标识：整块白框可点，点击后程序化聚焦
    enum LoginField: Hashable {
        case fnid, manualAddress, username, password, accessCode
    }

    @FocusState private var focusedField: LoginField?

    @State private var fnId = ""
    @State private var manualAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var accessCode = ""
    @State private var rememberPassword = true

    private var canSubmit: Bool {
        (!fnId.trimmed.isEmpty || !manualAddress.trimmed.isEmpty)
        && !username.trimmed.isEmpty
        && !password.isEmpty
        && !session.isWorking
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                connectionSection
                accountSection
                accessCodeSection
                submitSection
            }
            .padding(.horizontal, 22)
            // 顶部留白 = 安全区 + 这里的 padding，28 会叠得太高，顶部单独收小
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(PodTheme.bodyGradient.ignoresSafeArea())
        .onAppear(perform: prefill)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PodTheme.screenBezel)
                    .frame(width: 132, height: 99)
                VStack(spacing: 2) {
                    Text("NiuPod")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("飞牛音乐 · iPod 版")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Text("连接你的飞牛 NAS 音乐库")
                .font(.system(size: 13))
                .foregroundStyle(PodTheme.rowSecondary)
        }
    }

    // MARK: - 连接

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("连接方式")

            podField("FNID", text: $fnId, field: .fnid, placeholder: "如 abc12345",
                     keyboard: .asciiCapable, autocapitalization: .none)
                .disabled(!manualAddress.trimmed.isEmpty)

            HStack(spacing: 8) {
                Rectangle().fill(PodTheme.rowSeparator).frame(height: 1)
                Text("或").font(.system(size: 11)).foregroundStyle(PodTheme.rowSecondary)
                Rectangle().fill(PodTheme.rowSeparator).frame(height: 1)
            }

            podField("服务器地址", text: $manualAddress, field: .manualAddress,
                     placeholder: "http://192.168.1.2:5666",
                     keyboard: .URL, autocapitalization: .none)
                .disabled(!fnId.trimmed.isEmpty)

            Text("推荐使用 FNID：会自动在「内网 / 公网 IPv6 / 公网 IPv4 / 中继」之间挑最快的链路。")
                .font(.system(size: 10))
                .foregroundStyle(PodTheme.rowSecondary)
        }
        .podCard()
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("账号")
            podField("用户名", text: $username, field: .username, placeholder: "飞牛账号",
                     keyboard: .default, autocapitalization: .none)
            SecureInputField(title: "密码", text: $password,
                             focusedField: $focusedField, field: .password)
        }
        .podCard()
    }

    private var accessCodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("安全码（可选）")
            podField("安全码", text: $accessCode, field: .accessCode,
                     placeholder: "服务器开启访问码时填写",
                     keyboard: .default, autocapitalization: .none)
        }
        .podCard()
        .opacity(session.needsAccessCode ? 1 : 0.75)
        .overlay(alignment: .topTrailing) {
            if session.needsAccessCode {
                Text("需要")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
                    .offset(x: -12, y: 8)
            }
        }
    }

    // MARK: - 提交

    private var submitSection: some View {
        VStack(spacing: 12) {
            Button {
                submit()
            } label: {
                HStack(spacing: 8) {
                    if session.isWorking { ProgressView().tint(.white).scaleEffect(0.8) }
                    Text(session.isWorking ? "连接中…" : "连接")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(.white)
                .background(canSubmit ? PodTheme.selectedBottom : Color.gray.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(!canSubmit)

            if let message = session.message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(session.isLoggedIn ? .green : .red)
                    .multilineTextAlignment(.center)
            }
            if let method = session.lastProbeMethod {
                Text("链路：\(method)")
                    .font(.system(size: 10))
                    .foregroundStyle(PodTheme.rowSecondary)
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PodTheme.sectionHeader)
    }

    private func podField(
        _ title: String,
        text: Binding<String>,
        field: LoginField,
        placeholder: String,
        keyboard: UIKeyboardType,
        autocapitalization: UITextAutocapitalizationType
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(PodTheme.rowSecondary)
            ZStack(alignment: .leading) {
                TextField(placeholder, text: text)
                    .focused($focusedField, equals: field)
                    .keyboardType(keyboard)
                    .autocapitalization(autocapitalization)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 14))
                    .padding(.horizontal, 10)
            }
            .frame(height: 40)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PodTheme.rowSeparator, lineWidth: 1)
            )
            // 整块白框都可点：TextField 原生只响应文字区，白框其余位置
            // 由外层容器接住并程序化聚焦
            .contentShape(Rectangle())
            .onTapGesture { focusedField = field }
        }
    }

    // MARK: - 动作

    private func prefill() {
        if fnId.isEmpty { fnId = session.credentials.fnId }
        if manualAddress.isEmpty, session.credentials.fnId.isEmpty {
            manualAddress = session.credentials.baseUrl
        }
        if username.isEmpty { username = session.credentials.username }
        if password.isEmpty { password = CredentialsStore.loadPassword() ?? "" }
        if accessCode.isEmpty { accessCode = session.credentials.accessCode ?? "" }
    }

    private func submit() {
        session.credentials.accessCode = accessCode.trimmed.isEmpty ? nil : accessCode.trimmed
        Task {
            await session.login(
                fnId: manualAddress.trimmed.isEmpty ? fnId : nil,
                manualAddress: manualAddress.trimmed.isEmpty ? nil : manualAddress,
                username: username,
                password: password
            )
            if !rememberPassword { CredentialsStore.savePassword("") }
        }
    }
}

struct SecureInputField: View {
    let title: String
    @Binding var text: String
    var focusedField: FocusState<LoginView.LoginField?>.Binding
    let field: LoginView.LoginField
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(PodTheme.rowSecondary)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if isVisible {
                        TextField(title, text: $text)
                            .font(.system(size: 14))
                            .focused(focusedField, equals: field)
                    } else {
                        SecureField(title, text: $text)
                            .font(.system(size: 14))
                            .focused(focusedField, equals: field)
                    }
                    Button {
                        isVisible.toggle()
                    } label: {
                        Image(systemName: isVisible ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundStyle(PodTheme.rowSecondary)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 40)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PodTheme.rowSeparator, lineWidth: 1)
            )
            // 整块白框都可点聚焦
            .contentShape(Rectangle())
            .onTapGesture { focusedField.wrappedValue = field }
        }
    }
}

// MARK: - 卡片容器

struct PodCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
            )
    }
}

extension View {
    func podCard() -> some View { modifier(PodCardModifier()) }
}
