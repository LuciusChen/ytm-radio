use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelperError {
    pub code: &'static str,
    pub message: String,
    pub retryable: bool,
    pub auth_required: bool,
}

impl HelperError {
    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new("invalid-request", message, false, false)
    }

    pub fn auth_required(message: impl Into<String>) -> Self {
        Self::new("auth-required", message, false, true)
    }

    pub fn browser_restart_required(message: impl Into<String>) -> Self {
        Self::new("browser-restart-required", message, false, false)
    }

    pub fn network(message: impl Into<String>) -> Self {
        Self::new("network", message, true, false)
    }

    pub fn remote_response(message: impl Into<String>) -> Self {
        Self::new("remote-response", message, true, false)
    }

    pub fn helper_failure(message: impl Into<String>) -> Self {
        Self::new("helper-failure", message, false, false)
    }

    pub fn context(mut self, context: impl AsRef<str>) -> Self {
        self.message = format!("{}: {}", context.as_ref(), self.message);
        self
    }

    fn new(
        code: &'static str,
        message: impl Into<String>,
        retryable: bool,
        auth_required: bool,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            retryable,
            auth_required,
        }
    }
}

impl fmt::Display for HelperError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for HelperError {}

impl From<String> for HelperError {
    fn from(message: String) -> Self {
        Self::helper_failure(message)
    }
}

impl From<&str> for HelperError {
    fn from(message: &str) -> Self {
        Self::helper_failure(message)
    }
}

pub type Result<T> = std::result::Result<T, HelperError>;
