package dev.svoi.app

import android.os.Bundle
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Parcelable

class BackendReply(private val text: String?, private val stream: ParcelFileDescriptor?) : Parcelable {
    override fun describeContents() = if (stream == null) 0 else Parcelable.CONTENTS_FILE_DESCRIPTOR
    override fun writeToParcel(parcel: Parcel, flags: Int) {
        parcel.writeString(text)
        // Forward RETURN_VALUE so Binder closes the sender's copy of the pipe.
        parcel.writeParcelable(stream, flags)
    }
    fun read(): String = BackendParcel.read(Bundle().apply { putString("text", text); putParcelable("stream", stream) })
    companion object CREATOR : Parcelable.Creator<BackendReply> {
        @Suppress("DEPRECATION")
        override fun createFromParcel(parcel: Parcel) = BackendReply(parcel.readString(), parcel.readParcelable(ParcelFileDescriptor::class.java.classLoader))
        override fun newArray(size: Int): Array<BackendReply?> = arrayOfNulls(size)
    }
}
