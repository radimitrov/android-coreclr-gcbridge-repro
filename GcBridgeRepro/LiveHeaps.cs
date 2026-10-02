using Android.Runtime;

namespace GcBridgeRepro;

/// <summary>
/// Long-lived Java and managed objects, built once per process before the measured phase.
/// A real app has both: without a live Java heap, the full ART collection each bridge round
/// starts (<c>java.lang.Runtime.gc()</c>) finishes in a few ms and nothing waits for long.
/// </summary>
static class LiveHeaps
{
    static readonly List<IntPtr> s_javaRoots = new();
    static object?[]? s_managed;

    public static int JavaObjects { get; private set; }
    public static int ManagedMB { get; private set; }

    /// <summary>
    /// Builds <paramref name="objects"/> Java objects as 16 <c>java.util.LinkedList</c>s held by
    /// JNI global references. Each list is built by Java itself (<c>new LinkedList(Collections.nCopies(n, x))</c>),
    /// so the whole heap costs two JNI calls per list rather than one per object, and ART has a
    /// long pointer chain to mark on every collection.
    /// </summary>
    public static void EnsureJava(int objects)
    {
        if (JavaObjects > 0 || objects <= 0)
            return;

        const int lists = 16;
        int perList = objects / lists;
        IntPtr collections = JNIEnv.FindClass("java/util/Collections");
        IntPtr nCopies = JNIEnv.GetStaticMethodID(collections, "nCopies", "(ILjava/lang/Object;)Ljava/util/List;");
        IntPtr linkedList = JNIEnv.FindClass("java/util/LinkedList");
        IntPtr ctor = JNIEnv.GetMethodID(linkedList, "<init>", "(Ljava/util/Collection;)V");

        using var filler = new Java.Lang.String("filler");
        for (int i = 0; i < lists; i++)
        {
            IntPtr copies = JNIEnv.CallStaticObjectMethod(collections, nCopies, new JValue(perList), new JValue(filler));
            IntPtr list = JNIEnv.NewObject(linkedList, ctor, new JValue(copies));
            s_javaRoots.Add(JNIEnv.NewGlobalRef(list));
            JNIEnv.DeleteLocalRef(list);
            JNIEnv.DeleteLocalRef(copies);
        }
        JavaObjects = perList * lists;
    }

    /// <summary>Keeps roughly <paramref name="megabytes"/> MB of small managed objects reachable.</summary>
    public static void EnsureManaged(int megabytes)
    {
        if (s_managed is not null || megabytes <= 0)
            return;

        // Node (~32 B) + byte[64] (~88 B) per entry, plus the 8 B array slot.
        int count = (int)(megabytes * 1024L * 1024 / 128);
        var roots = new object?[count];
        for (int i = 0; i < count; i++)
            roots[i] = new Node { Value = i, Payload = new byte[64] };
        s_managed = roots;
        ManagedMB = megabytes;
    }
}

/// <summary>A small managed object with a payload, the unit of both the live heap and the garbage.</summary>
sealed class Node
{
    public long Value;
    public byte[]? Payload;
}
