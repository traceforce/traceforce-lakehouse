# Integer codes

Decode integer columns with these tables (from TraceForce's proto and public API vocabulary).

Contents: AgentIdentity (lake agents), AgentPlanType, AgentDeploymentType, SensitiveDataCategory, SensitiveDataType, FindingStatus, ContainmentOp, OperationOutcome, MCPTransportType, TransportSecurityType, MCPDeploymentModel, IdentityControlType (auth_type), MCPDistributionChannel, MCPSourceType, MCP category resource_type (IssueDetail subset), SandboxRuntimeType.

## AgentIdentity (lake agents)

| code | meaning |
|---|---|
| 1 | Claude (the claude.ai chat agent — any deployment; distinct from Claude Code, 111) |
| 2 | Cursor |
| 8 | GitHub Copilot |
| 111 | Claude Code |
| … | every other value: join agent_catalog on agent_type for the name |

## AgentPlanType

| code | meaning |
|---|---|
| 0 | unspecified |
| 1 | personal |
| 2 | enterprise |
| 3 | small_business |

## AgentDeploymentType

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | desktop_app |
| 2 | vscode_extension |
| 3 | cli |
| 4 | browser |
| 5 | ai_browser |
| 6 | service |

## SensitiveDataCategory

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | credentials |
| 2 | identity_financial_pii |
| 3 | contact_pii |

## SensitiveDataType

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | api_key |
| 2 | private_key |
| 3 | password |
| 4 | database_connection_string |
| 100 | ssn |
| 101 | credit_card |
| 102 | bank_account_number |
| 103 | government_id |
| 200 | email_address |
| 201 | phone_number |
| 202 | physical_address |

## FindingStatus

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | awaiting_review |
| 2 | under_review |
| 3 | false_positive |
| 4 | revoked |
| 5 | used_in_tests |
| 6 | wont_fix |
| 7 | acknowledged |

Open, as the API's open_count uses it, is finding_status IN (1, 2) on both findings tables; every other value, including 0 (unknown) and 7 (acknowledged), counts as closed.

## ContainmentOp

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | write |
| 2 | delete |

## OperationOutcome

| code | meaning |
|---|---|
| 0 | unspecified |
| 1 | executed |
| 2 | failed |
| 3 | denied (never stored: denied events are dropped before the table) |

## MCPTransportType

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | stdio |
| 2 | http |
| 3 | sse |

## TransportSecurityType

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | none |
| 2 | tls |

## MCPDeploymentModel

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | local_process |
| 2 | local_container |
| 3 | local_service |
| 4 | remote |

## IdentityControlType (auth_type)

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | basic_auth |
| 2 | token |
| 3 | oauth |
| 4 | no_auth |

## MCPDistributionChannel

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | platform (managed_by=admin) |
| 2 | tenant (managed_by=admin) |
| 3 | user (managed_by=user) |

## MCPSourceType

| code | meaning |
|---|---|
| 0 | unknown |
| 1 | official |
| 2 | community |
| 3 | reference |
| 4 | archived |
| 5 | openai |
| 6 | anthropic |

## MCP category resource_type (IssueDetail subset)

| code | meaning |
|---|---|
| 10120 | public |
| 10121 | internal_apps |
| 10122 | dev_tools |
| 10123 | database_infrastructure |
| 10124 | local_system |

## SandboxRuntimeType

| code | meaning |
|---|---|
| 0 | unspecified |
| 1 | devcontainer |

## Not enumerated

- `mcp_server_type` (instances, rollups, catalogs): a product code, join `mcp_catalog` / `org_mcp_catalog` for the name.
- `mcp_servers.mcp_server_status`: TraceForce internal lifecycle code.
