package dev.svoi.app;
import android.os.Bundle;
import dev.svoi.app.BackendReply;

interface IBackendService {
    BackendReply call(in Bundle request);
}
