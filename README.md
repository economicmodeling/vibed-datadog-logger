# vibed-datadog-logger
Datadog logger implementation for Vibe.d

## Example

```d
void main()
{
    import vibe.core.log : logInfo, registerLogger;
    import vibe_datadog_logger : DatadogInfo, DatadogLogger;
    import core.time : dur;

    DatadogInfo info;
    info.ingestEndpoint = "https://http-intake.logs.datadoghq.com";
    info.apiKey = "1234567890";
    info.sourceName = "myApp";
    info.serviceName = "datadog-logger";
    info.hostName = "linux-x64";
    info.environment = "prod";

    auto l = cast(shared) new DatadogLogger(info, dur!"seconds"(5), 30);
    registerLogger(l);
}
```